{-# LANGUAGE TemplateHaskell #-}

module Polysemy.EventSourcing where

import Control.Concurrent (Chan)
import Data.Text (Text)
import Polysemy (Embed, Member, Members, Sem)
import Polysemy.KVStore (KVStore)
import Prelude hiding (lookup)
import qualified Control.Concurrent.Chan as Chan
import qualified Data.Maybe as Maybe
import qualified Polysemy
import qualified Polysemy.KVStore as KVStore

newtype PersistenceId =
  PersistenceId Text
  deriving (Show, Eq, Ord)

data StateStorage s m a where
  Lookup :: PersistenceId -> StateStorage s m (Maybe s)
  Write :: s -> PersistenceId -> StateStorage s m ()
  Modify :: s -> (s -> s) -> PersistenceId -> StateStorage s m ()

Polysemy.makeSem ''StateStorage

runStateStorageAsKVStore :: Sem (StateStorage s ': r) a -> Sem (KVStore PersistenceId s ': r) a
runStateStorageAsKVStore = Polysemy.reinterpret $ \case
  Lookup id ->
    KVStore.lookupKV id

  Write s id ->
    KVStore.writeKV id s

  Modify s f id ->
    KVStore.modifyKV s f id

data EventJournal s e m a where
  Persist :: e -> PersistenceId -> EventJournal s e m ()
  Replay :: (s -> e -> s) -> s -> PersistenceId -> EventJournal s e m s

Polysemy.makeSem ''EventJournal

runEventJournalKVStore :: Sem (EventJournal s e ': r) a -> Sem (KVStore PersistenceId [e] ': r) a
runEventJournalKVStore = Polysemy.reinterpret $ \case
  Persist event id ->
    KVStore.modifyKV [] (event :) id

  Replay f init id ->
    foldl f init . Maybe.fromMaybe [] <$> KVStore.lookupKV id

data EventSourcing s e m a where
  Log :: e -> PersistenceId ->  EventSourcing s e m ()
  Get :: PersistenceId -> EventSourcing s e m s
  Subscribe :: EventSourcing s e m (Chan (PersistenceId, e))

Polysemy.makeSem ''EventSourcing

runEventSourcing :: forall s e r a. Members '[StateStorage s, EventJournal s e, Embed IO] r => (s -> e -> s) -> s -> Chan (PersistenceId, e) -> Sem (EventSourcing s e ': r) a -> Sem r a
runEventSourcing f init chan =
  Polysemy.interpret $ \case
    Log event id ->
      persist event id
        >> modify init (`f` event) id
        >> Polysemy.embed (Chan.writeChan chan (id, event))

    Get id -> do
      mState <- lookup id
      case mState of
        Nothing -> do
          state <- replay f init id
          write state id
          return state
        Just state ->
          return state

    Subscribe ->
      Polysemy.embed $ Chan.dupChan chan
