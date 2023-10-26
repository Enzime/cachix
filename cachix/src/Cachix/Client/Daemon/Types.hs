{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Cachix.Client.Daemon.Types where

import Cachix.Client.Config.Orphans ()
import Cachix.Client.Env as Env
import Cachix.Client.OptionsParser (PushOptions)
import Cachix.Client.Push
import Cachix.Types.BinaryCache (BinaryCacheName)
import Control.Concurrent.MVar
import Control.Concurrent.STM.TBMQueue
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import qualified Katip
import qualified Network.Socket as Socket
import Protolude hiding (bracketOnError)

data DaemonEnv = DaemonEnv
  { -- | Cachix client env
    daemonEnv :: Env,
    -- | Push options, like compression settings
    daemonPushOptions :: PushOptions,
    -- | Path to the socket that the daemon listens on
    daemonSocketPath :: FilePath,
    -- | Queue of push requests to be processed by the worker thread
    daemonQueue :: TBMQueue QueuedPushRequest,
    -- | The binary cache to push to
    daemonCacheName :: BinaryCacheName,
    -- | The push secret for the binary cache
    daemonPushSecret :: PushSecret,
    -- | Logger namespace
    daemonKNamespace :: Katip.Namespace,
    -- | Logger context
    daemonKContext :: Katip.LogContexts,
    -- | Logger env
    daemonKLogEnv :: Katip.LogEnv,
    -- | Shutdown latch
    daemonShutdownLatch :: ShutdownLatch
  }

newtype Daemon a = Daemon
  { unDaemon :: ReaderT DaemonEnv IO a
  }
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadReader DaemonEnv,
      MonadUnliftIO,
      MonadCatch,
      MonadMask,
      MonadThrow
    )

instance Katip.Katip Daemon where
  getLogEnv = asks daemonKLogEnv
  localLogEnv f (Daemon m) = Daemon (local (\s -> s {daemonKLogEnv = f (daemonKLogEnv s)}) m)

instance Katip.KatipContext Daemon where
  getKatipContext = asks daemonKContext
  localKatipContext f (Daemon m) = Daemon (local (\s -> s {daemonKContext = f (daemonKContext s)}) m)

  getKatipNamespace = asks daemonKNamespace
  localKatipNamespace f (Daemon m) = Daemon (local (\s -> s {daemonKNamespace = f (daemonKNamespace s)}) m)

-- | Run a pre-configured daemon.
runDaemon :: DaemonEnv -> Daemon a -> IO a
runDaemon env f = do
  let registerScribe = do
        scribeHandle <- Katip.mkHandleScribe Katip.ColorIfTerminal stdout (Katip.permitItem Katip.DebugS) Katip.V2
        Katip.registerScribe "stdout" scribeHandle Katip.defaultScribeSettings (daemonKLogEnv env)

  bracket registerScribe Katip.closeScribes $ \logEnv -> do
    unDaemon f `runReaderT` env {daemonKLogEnv = logEnv}

showConfiguration :: Daemon Text
showConfiguration = do
  DaemonEnv {..} <- ask
  pure $
    unlines
      [ "Cache: " <> toS daemonCacheName,
        "Socket: " <> toS daemonSocketPath
      ]

-- | JSON messages that the client can send to the daemon
data ClientMessage
  = ClientPushRequest PushRequest
  | ClientStop
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data DaemonMessage
  = DaemonBye
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

-- | A request for the daemon to push store paths to a binary cache
data PushRequest = PushRequest
  { storePaths :: [FilePath]
  }
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data QueuedPushRequest = QueuedPushRequest
  { -- | The original push request
    pushRequest :: PushRequest,
    -- | An open socket to the client that sent the push request.
    clientConnection :: Socket.Socket
  }

-- | A latch to keep track of the shutdown process.
newtype ShutdownLatch = ShutdownLatch {unShutdownLatch :: MVar ()}

newShutdownLatch :: (MonadIO m) => m ShutdownLatch
newShutdownLatch = ShutdownLatch <$> liftIO newEmptyMVar

waitForShutdown :: (MonadIO m) => ShutdownLatch -> m ()
waitForShutdown = liftIO . readMVar . unShutdownLatch

initiateShutdown :: (MonadIO m) => ShutdownLatch -> m ()
initiateShutdown = void . liftIO . flip tryPutMVar () . unShutdownLatch

isShuttingDown :: (MonadIO m) => ShutdownLatch -> m Bool
isShuttingDown = liftIO . fmap not . isEmptyMVar . unShutdownLatch
