{-# LANGUAGE GeneralizedNewtypeDeriving,
             DoAndIfThenElse,
             ScopedTypeVariables,
             DeriveFunctor,
             TypeFamilies #-}

module Control.StartStop.Core where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Monad.Reader
import Control.Monad.Writer.Strict
import qualified Control.StartStop.Class as Class
import Control.StartStop.Class ((.:), ffilter)
import Control.Arrow
import Control.StartStop.Prim

import Data.IORef
import Data.Monoid
import Data.Functor.Compose

import System.IO.Unsafe
import System.Mem.Weak


data ActiveInfo = Active | ActiveFuture | NotActive deriving(Show, Eq)
newtype Activity t = Activity (Sample t ActiveInfo)
data TimeValue t a = TimeValue !a !(Activity t) !(RoundSequence t) deriving (Functor)

instance Monoid (Activity t) where
  mempty = Activity $ return Active
  mappend (Activity l) (Activity r) = Activity (liftA2 cmp l r)
    where
      cmp Active x = x
      cmp x Active = x
      cmp NotActive _ = NotActive
      cmp _ NotActive = NotActive
      cmp ActiveFuture ActiveFuture = ActiveFuture

instance Applicative (TimeValue t) where
  pure = return
  (<*>) = ap

instance Monad (TimeValue t) where
  return x = TimeValue x mempty mempty
  (TimeValue a aactive ase) >>= f = TimeValue b (aactive <> bactive) (ase <> bse)
    where
      (TimeValue b bactive bse) = f a

data EvInfo t a = NotFired
                | FiredNow !a !(RoundSequence t) deriving(Functor)

data EvStream t a = Never
                  | EvStream (Sample t (EvInfo t a))

sampleEvStream :: EvStream t a -> Sample t (EvInfo t a)
sampleEvStream Never = return NotFired
sampleEvStream (EvStream sEInfo) = sEInfo

memoEvs :: EvStream t a -> EvStream t a
memoEvs Never = Never
memoEvs (EvStream sampleEvs) = EvStream $ memoSample sampleEvs

instance Functor (EvStream t) where
  fmap f evs = memoEvs (noMemoEMap f evs)

noMemoEMap :: (a -> b) -> EvStream t a -> EvStream t b
noMemoEMap f Never = Never
noMemoEMap f (EvStream sValue) = EvStream $ fmap (fmap f) sValue

instance Class.FilterFunctor (EvStream t) where
  filterMap = catMaybeEs .: fmap

newtype Behavior t a = Behavior { runB :: Sample t (TimeValue t a) }

instance Functor (Behavior t) where
  fmap = liftM

instance Applicative (Behavior t) where
  pure = return
  (<*>) = ap

instance Monad (Behavior t) where
  return x = Behavior $ return $ return x
  (Behavior sTime) >>= f = memoB $ Behavior $ do
    (TimeValue a aactive ase) <- sTime
    (TimeValue b bactive bse) <- runB $ f a
    return $ TimeValue b (aactive <> bactive) (ase <> bse)

instance MonadFix (Behavior t) where
  mfix f = Behavior $ mfix (\(~(TimeValue a _ _)) -> runB $ f a)

noMemoBMap :: (a -> b) -> Behavior t a -> Behavior t b
noMemoBMap f = Behavior . fmap (fmap f) . runB

{-# NOINLINE memoB #-}
memoB :: Behavior t a -> Behavior t a
memoB b = unsafePerformIO $ do
  ref <- newIORef Nothing
  return $ usePrevB ref b

usePrevB :: IORef (Maybe (TimeValue t a)) -> Behavior t a -> Behavior t a
usePrevB ref b = Behavior $ do
  let reRun = do
        tv <- runB b
        liftIO $ writeIORef ref (Just tv)
        return tv
  mtv <- liftIO $ readIORef ref
  case mtv of
    Just tv@(TimeValue v (Activity activity) se) -> do
      aInfo <- activity
      case aInfo of
        NotActive -> reRun
        Active -> return tv
        _ -> error "Invariant Broken."
    _ -> reRun

data Reactive t a = Reactive { changes_ :: EvStream t (a, Activity t)
                             , sampleCurrent :: Sample t (TimeValue t a)
                             }

{-# NOINLINE memoR #-}
memoR :: Reactive t a -> Reactive t a
memoR r = unsafePerformIO $ do
  currentRef <- newIORef Nothing
  futureRef <- newIORef Nothing
  return $ usePrevR currentRef futureRef r

usePrevR :: forall t a . IORef (Maybe (TimeValue t a))
         -> IORef (Maybe (Time, Maybe (TimeValue t a)))
         -> Reactive t a
         -> Reactive t a
usePrevR currentRef futureRef r = Reactive readChanges readCurrent
  where
    reRunCurrent = do
      tv <- sampleCurrent r
      liftIO $ writeIORef currentRef (Just tv)
      return tv

    reRunFuture = do
      eInfo <- sampleEvStream (changes_ r)
      t <- getCurTime
      case eInfo of
        NotFired -> do
          liftIO $ writeIORef futureRef (Just (t, Nothing))
          return NotFired
        FiredNow (v, activity) rs -> do
          liftIO $ writeIORef futureRef (Just (t, Just $ TimeValue v activity rs))
          return $ FiredNow (v, activity) rs

    readCurrent = do
      mtv <- liftIO $ readIORef currentRef
      case mtv of
        Just tv@(TimeValue _ (Activity av) _) -> do
          aInfo <- av
          case aInfo of
            NotActive -> readFuture
            Active -> return tv
            ActiveFuture -> error "Invariant broken."
        _ -> readFuture

    readFuture = do
      mtv <- liftIO $ readIORef futureRef
      case mtv of
        Just (t, Just tv@(TimeValue _ (Activity av) _)) -> do
          aInfo <- av
          case aInfo of
            Active -> do
              liftIO $ writeIORef currentRef (Just tv)
              return tv
            _ -> reRunCurrent
        _ -> reRunCurrent

    readChanges = EvStream $ do
      mttv <- liftIO $ readIORef futureRef
      case mttv of
        Just (t, mtv) -> do
          curTime <- getCurTime
          if t == curTime
          then case mtv of
                Nothing -> return NotFired
                Just tv@(TimeValue v act rs) -> return $ FiredNow (v, act) rs
          else reRunFuture
        _ -> reRunFuture

instance Functor (Reactive t) where
  fmap = memoR .: noMemoRMap

noMemoRMap :: (a -> b) -> Reactive t a -> Reactive t b
noMemoRMap f r = Reactive (first f <$> changes_ r) $ do
  (TimeValue a active se) <- sampleCurrent r
  return $ TimeValue (f a) active se

instance Applicative (Reactive t) where
  pure = return
  (<*>) = ap

instance Monad (Reactive t) where
  return x = Reactive never (return $ return x)
  ra >>= f = joinR (fmap f ra)

joinR :: forall t a . Reactive t (Reactive t a) -> Reactive t a
joinR rra = Reactive changesA $ do
  (TimeValue ra raactive rase) <- sampleCurrent rra
  (TimeValue a aactive ase) <- sampleCurrent ra
  return $ TimeValue a (raactive <> aactive) (rase <> ase)

  where
    changesA :: EvStream t (a, Activity t)
    changesA = EvStream $ do
      rraChangeInfo <- sampleEvStream $ changes_ rra
      case rraChangeInfo of
        NotFired -> do
          (TimeValue ra raactive rase) <- sampleCurrent rra
          raChangeInfo <- sampleEvStream $ changes_ ra
          case raChangeInfo of
            NotFired -> return NotFired
            FiredNow (a', aactive) sera' -> return $ FiredNow (a', raactive <> aactive) (rase <> sera')

        FiredNow (ra', raactive) prra' -> do
          raChangeInfo <- sampleEvStream $ changes_ ra'
          case raChangeInfo of
            NotFired -> do
              (TimeValue a aactive ase) <- sampleCurrent ra'
              return $ FiredNow (a, raactive <> aactive) (prra' <> ase)
            FiredNow (a', aactive) sera' -> return $ FiredNow (a', raactive <> aactive) (prra' <> sera')

never :: EvStream t a
never = Never

coincidence :: EvStream t (EvStream t a) -> EvStream t a
coincidence Never = Never
coincidence eevs = EvStream $ do
  evsInfo <- sampleEvStream eevs
  case evsInfo of
    NotFired -> return NotFired
    FiredNow evs pOut -> do
      eInfo <- sampleEvStream evs
      case eInfo of
        NotFired -> return NotFired
        FiredNow v pIn -> return $ FiredNow v (pOut <> pIn)

catMaybeEs :: EvStream t (Maybe a) -> EvStream t a
catMaybeEs Never = Never
catMaybeEs (EvStream sampleEvs) = EvStream $ do
  eInfo <- sampleEvs
  case eInfo of
    NotFired -> return NotFired
    FiredNow ma pma -> case ma of
      Nothing -> return NotFired
      Just a -> return $ FiredNow a pma

{--
-- "mergefEs f es1 es2" is an EvStream that fires when either e1 or e2
-- fires. If e1 and e2 fire at the same time, let v1 be the value of the event
-- fired by e1, and v2 be the value of the event fired by e2. Then "mergefEs f es1 es2"
-- fires with a value of "f v1 v2"
--}
mergefEs :: (a -> a -> a) -> EvStream t a -> EvStream t a -> EvStream t a
mergefEs _ Never e = e
mergefEs _ e Never = e
mergefEs f (EvStream mel) (EvStream mer) = EvStream $ do
  el <- mel
  er <- mer
  case (el, er) of
    (NotFired, NotFired) -> return NotFired
    (FiredNow l p, NotFired) -> return $ FiredNow l p
    (NotFired, FiredNow r p) -> return $ FiredNow r p
    (FiredNow l pl, FiredNow r pr) -> return $ FiredNow (f l r) (pl <> pr)

switch :: Behavior t (EvStream t a) -> EvStream t a
switch bevs = EvStream $ do
  (TimeValue evs _ brs) <- runB bevs
  case evs of
    Never -> return NotFired
    EvStream em' -> do
      einfo <- em'
      case einfo of
        NotFired -> return NotFired
        FiredNow v rs -> return $ FiredNow v (brs <> rs)

samples :: EvStream t (Behavior t a) -> EvStream t a
samples Never = Never
samples (EvStream sampleEvs) = EvStream $ do
  eInfo <- sampleEvs
  case eInfo of
    NotFired -> return NotFired
    FiredNow ba pba -> do
      (TimeValue a _ pa) <- runB ba
      return $ FiredNow a (pba <> pa)

sampleR :: Reactive t a -> Behavior t a
sampleR r = Behavior $ sampleCurrent r

sampleRAfter :: Reactive t a -> Behavior t a
sampleRAfter r = Behavior $ do
  changeInfo <- sampleEvStream (changes_ r)
  case changeInfo of
    NotFired -> sampleCurrent r
    FiredNow (v', vactive) p' -> return $ TimeValue v' vactive p'

changes :: Reactive t a -> EvStream t a
changes = noMemoEMap fst . changes_

newtype Plans t = Plans (EvStream t ())

instance Monoid (Plans t) where
  mempty = Plans never
  mappend (Plans el) (Plans er) = Plans $ mergefEs (<>) el er

data Env = Env { clock :: IO Time
               , scheduleRound :: IO ()
               }
newtype PlanHold t a = PlanHold { unPlanHold :: WriterT (Plans t, RoundSequence t) (ReaderT Env IO) a } deriving (Functor, Applicative, Monad, MonadFix, MonadIO)

unsafeIOSequence :: EvStream t (IO a) -> IO (EvStream t a)
unsafeIOSequence evs = do
  ref <- newMVar Nothing
  let unsafeEvs emio = EvStream $ do
        curTime <- getCurTime
        mOld <- liftIO $ takeMVar ref
        case mOld of
          Just (t, v, p)
            | t == curTime -> do
              liftIO $ putMVar ref mOld
              return $ FiredNow v p
            | t > curTime -> error "Invariant Broken."
          _ -> do
            mio <- emio
            case mio of
              NotFired -> do
                liftIO $ putMVar ref Nothing
                return NotFired
              FiredNow iov p -> do
                v <- liftIO iov
                t <- getCurTime
                liftIO $ putMVar ref (Just (t, v, p))
                return $ FiredNow v p

  return $ case evs of
            Never -> Never
            EvStream emio -> unsafeEvs emio

planEs :: EvStream t (IO a) -> PlanHold t (EvStream t a)
planEs Never = return Never
planEs evs = PlanHold $ do
  plans <- liftIO $ unsafeIOSequence evs
  tell (Plans $ void plans, mempty)
  return plans

sampleB :: Behavior t a -> PlanHold t a
sampleB b = PlanHold $ do
  iot <- asks clock
  t <- liftIO iot
  (TimeValue a _ p) <- liftIO $ runReaderT (unSample $ runB b) t
  tell (mempty, p)
  return a

createWeakStrongPair :: a -> IO (IORef a, Weak (IORef a))
createWeakStrongPair iv = do
  ref <- newIORef iv
  weakRef <- mkWeakIORef ref (return ())
  return (ref, weakRef)

holdEs :: forall t a . a -> EvStream t a -> Behavior t (Reactive t a)
holdEs iv evs = Behavior $ do
  startTime <- getCurTime

  (activeValueRef, activeValueWeakRef) <- liftIO $ createWeakStrongPair (iv, evs)
  activeRSRef <- liftIO $ newIORef mempty
  lastChangeRef <- liftIO $ newIORef Nothing

  let changeAction = RoundAction $ Compose $ do
        mAValueref <- liftIO $ deRefWeak activeValueWeakRef

        case mAValueref of
          Nothing -> return $ pure NoAction
          Just ref -> do
            t <- getCurTime
            (_, readFires) <- liftIO $ readIORef ref
            fireInfo <- sampleEvStream readFires
            case fireInfo of
              FiredNow v rs
                | startTime /= t -> getCompose $  writeIORefWrite ref (v, readFires)
                                               *> writeIORefWrite lastChangeRef (Just t)
                                               *> runAndCleanUp (writeIORefClean activeRSRef) rs
                                               *> pure changeAction

              _ -> do
                activeRS <- liftIO $ readIORef activeRSRef
                getCompose $  runAndCleanUp (writeIORefClean activeRSRef) activeRS
                           *> pure changeAction

  thisRS <- newRoundSequence changeAction

  let changes = EvStream $ do
        eTime <- getCurTime
        evInfo <- sampleEvStream evs
        case evInfo of
          FiredNow v se
            | startTime /= eTime -> do
              etSample <- liftIO $ readIORef lastChangeRef
              let lastChange = Activity $ do
                    curTime <- getCurTime
                    case compare eTime curTime of
                      LT -> do
                        t <- liftIO $ readIORef lastChangeRef
                        case compare t etSample of
                          EQ -> return Active
                          GT -> return NotActive
                      EQ -> return ActiveFuture
              return $ FiredNow (v, lastChange) se
          _ -> return NotFired

      cmp curTime = case compare startTime curTime of
        GT -> NotActive
        EQ -> Active
        LT -> error "Invariant Broken."

      reactive = Reactive changes $ do
        (v,_) <- liftIO $ readIORef activeValueRef
        tSample <- liftIO $ readIORef lastChangeRef
        let lastChange = Activity $ do
              t <- liftIO $ readIORef lastChangeRef
              case compare t tSample of
                GT -> return NotActive
                EQ -> return Active
                LT -> error "Invariant Broken."

        effects <- liftIO $ readIORef activeRSRef
        return $ TimeValue v lastChange effects

  return $ TimeValue reactive (Activity $ fmap cmp getCurTime) thisRS

data Core t
instance Class.StartStop (Core t) where
  newtype Behavior (Core t) a = B { unB :: Behavior t a } deriving (Functor, Applicative, Monad, MonadFix)
  newtype Reactive (Core t) a = R { unR :: Reactive t a } deriving (Functor, Applicative, Monad)
  newtype EvStream (Core t) a = E { unE :: EvStream t a } deriving (Functor, Class.FilterFunctor)

  never = E never
  merge e1 e2 = E $ mergefEs (\(Class.LeftFired a) (Class.RightFired b) -> Class.Simul a b) (noMemoEMap Class.LeftFired $ unE e1) (noMemoEMap Class.RightFired $ unE e2)
  samples = E . samples . noMemoEMap unB . unE
  switch = E . switch . noMemoBMap unE . unB
  coincidence = E . coincidence . noMemoEMap unE . unE
  holdEs iv evs = B $ noMemoBMap R $ holdEs iv (unE evs)
  sampleR = B . sampleR . unR
  sampleRAfter = B . sampleRAfter . unR
  changes = E . changes . unR

reallySeqList :: [a] -> b -> b
reallySeqList [] = seq []
reallySeqList (x:xs) = reallySeqList xs

callbackStream :: PlanHold t (a -> IO (), EvStream t [a])
callbackStream = do
  cl <- PlanHold $ asks clock
  sr <- PlanHold $ asks scheduleRound
  currentValRef <- liftIO $ newIORef Nothing
  futureValRef <- liftIO $ newIORef []

  let trigger v = do
        (T curTime) <- cl
        let t = T (curTime + 1)
        modifyIORef' futureValRef ((t, v):)
        sr

      evs = EvStream $ do
              t <- getCurTime
              mtvs <- liftIO $ readIORef currentValRef
              vs <- case mtvs of
                Just (t', vs)
                  | t' == t -> return vs
                _ -> do
                  tvs <- liftIO $ readIORef futureValRef
                  let vs' = fmap snd . ffilter (\(t', v) -> t == t') $ tvs
                  liftIO $ writeIORef currentValRef (Just (t, vs'))
                  liftIO $ modifyIORef' futureValRef (\vs -> let vs' = ffilter (\(t', v) -> t < t') vs in reallySeqList vs' vs')
                  return vs'

              --vs <- mapM return vs' -- fixes some leak that is caused by laziness with vs'

              case vs of
                [] -> return NotFired
                _ -> return $ FiredNow vs mempty

  _ <- planEs $ return () <$ evs
  return (trigger, evs)

instance Class.StartStopIO (Core t) where
  newtype PlanIO (Core t) a = PIO { unPIO :: IO a } deriving (Functor, Applicative, Monad, MonadFix, MonadIO)
  newtype PlanHold (Core t) a = P { unP :: PlanHold t a } deriving (Functor, Applicative, Monad, MonadFix, MonadIO)

  callbackStream = P $ fmap (second E) callbackStream
  planEs = P . fmap E . planEs . noMemoEMap unPIO . unE
  sampleB = P . sampleB . unB
