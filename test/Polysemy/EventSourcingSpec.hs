module Polysemy.EventSourcingSpec (spec) where

import Control.Applicative ((<*))
import Control.Concurrent (Chan)
import Control.Monad.IO.Class (liftIO)
import Data.Function ((&))
import Polysemy (Member, Sem)
import Polysemy.EventSourcing (EventJournal(..), EventSourcing(..), PersistenceId(..), StateStorage(..))
import Test.Hspec (Spec, hspec, describe, it, runIO, shouldBe)
import qualified Control.Concurrent.Chan as Chan
import qualified Data.Map as Map
import qualified Polysemy
import qualified Polysemy.EventSourcing as EventSourcing
import qualified Polysemy.KVStore as KVStore
import qualified Polysemy.State as State

newtype State =
  State Int
  deriving (Show, Eq)

data Event
  = Incremented
  | Decremented
  deriving (Show, Eq)

persistenceId :: PersistenceId
persistenceId = PersistenceId "Alice"

eventHandler :: State -> Event -> State
eventHandler (State s) Incremented = State (s + 1)
eventHandler (State s) Decremented = State (s - 1)

initState :: State
initState = State 0

mockStateStorage :: Maybe State -> Sem (StateStorage State ': r) a -> Sem r a
mockStateStorage state = Polysemy.interpret $ \case
  Lookup id -> return state
  Write s id -> return ()
  Modify s f id -> return ()

mockEventJournal :: Maybe State -> Sem (EventJournal State Event ': r) a -> Sem r a
mockEventJournal state = Polysemy.interpret $ \case
  Persist event id -> return ()
  Replay f init id -> return state

spec :: Spec
spec = do
  describe "EventSourcing.log" $ do
    it "persists an event and publishes to the channel(s)" $ do
      log <- liftIO $ do
        chan <- Chan.newChan @(PersistenceId, Event)
        
        EventSourcing.log Incremented persistenceId
          & EventSourcing.runEventSourcing eventHandler initState chan
          & mockStateStorage Nothing
          & mockEventJournal Nothing
          & Polysemy.runM

        Chan.readChan chan

      log `shouldBe` (persistenceId, Incremented)
  
  describe "EventSourcing.get" $ do
    it "fetches states from storage" $ do
      state <- liftIO $ do
        chan <- Chan.newChan @(PersistenceId, Event)
        EventSourcing.get persistenceId
          & EventSourcing.runEventSourcing eventHandler initState chan
          & mockStateStorage (Just (State 0))
          & mockEventJournal Nothing
          & Polysemy.runM
      
      state `shouldBe` Just (State 0)
    
    it "replays states from journal" $ do
      state <- liftIO $ do
        chan <- Chan.newChan @(PersistenceId, Event)
        EventSourcing.get persistenceId
          & EventSourcing.runEventSourcing eventHandler initState chan
          & mockStateStorage Nothing
          & mockEventJournal (Just (State 0))
          & Polysemy.runM
      
      state `shouldBe` Just (State 0)

    it "returns nothing when key cannot be found" $ do
      state <- liftIO $ do
        chan <- Chan.newChan @(PersistenceId, Event)
        EventSourcing.get persistenceId
          & EventSourcing.runEventSourcing eventHandler initState chan
          & mockStateStorage Nothing
          & mockEventJournal Nothing
          & Polysemy.runM
      
      state `shouldBe` Nothing
  
  describe "EventSourcing.subscribe" $ do
    it "returns a new broadcast channel" $ do
      (logS, logC) <- liftIO $ do
        chan <- Chan.newChan @(PersistenceId, Event)
        
        sub <- (EventSourcing.subscribe <* EventSourcing.log Incremented persistenceId)
          & EventSourcing.runEventSourcing eventHandler initState chan
          & mockStateStorage Nothing
          & mockEventJournal Nothing
          & Polysemy.runM

        (,) <$> Chan.readChan chan <*> Chan.readChan sub

      logS `shouldBe` logC
