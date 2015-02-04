{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}
{-# LANGUAGE ViewPatterns                             #-}

{-# OPTIONS  #-}

module Thentos (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, throw, catch)
import Control.Monad (void)
import Data.Acid (AcidState, openLocalStateFrom, createCheckpoint, closeAcidState)
import Data.Acid.Advanced (query', update')
import Data.String.Conversions ((<>))
import System.Log.Logger (removeAllHandlers)
import Text.Show.Pretty (ppShow)

import Config (configLogger, getCommandWithConfig, Command(..), ServiceConfig(..), BackendConfig(..), FrontendConfig(..))
import Types
import DB
import Backend.Api.Simple (runApi, apiDocs)
import Frontend (runFrontend)


-- * main

main :: IO ()
main =
  do
    putStr "setting up acid-state..."
    st :: AcidState DB <- openLocalStateFrom ".acid-state/" emptyDB
    putStrLn " [ok]"

    createGod st True
    configLogger

    -- FIXME: error handling (produce a helpful error message and quit)
    Right cmd <- getCommandWithConfig
    let run = case cmd of
                ShowDB -> do
                    putStrLn "database contents:"
                    query' st (SnapShot allowEverything) >>= either (error "oops?") (putStrLn . ppShow)
                AddData "user" -> do
                    putStrLn "adding dummy user to database:"
                    void . update' st $ AddUser (User "dummy" "dummy" "dummy" [] []) allowEverything
                AddData "service" -> do
                    putStrLn "adding dummy service to database:"
                    sid <- update' st $ AddService allowEverything
                    putStrLn $ "Service id: " ++ show sid
                Run config -> do
                {-
                switch ["-r"
                       , fromMaybe 8001 . readMay -> backendPort
                       , fromMaybe 8002 . readMay -> frontendPort
                       ] = do
                -}
                    let backend = case backendConfig config of
                            Nothing -> return ()
                            Just (BackendConfig backendPort) -> do
                                putStrLn $ "running rest api on localhost:" <> show backendPort <> "."
                                runApi backendPort st

                    let frontend = case frontendConfig config of
                            Nothing -> return ()
                            Just (FrontendConfig frontendPort) -> do
                                putStrLn $ "running frontend on localhost:" <> show frontendPort <> "."
                                putStrLn "Press ^C to abort."
                                runFrontend "localhost" frontendPort st
                    _ <- createCheckpointLoop st 16000 Nothing
                    void $ concurrently backend frontend

                Docs -> putStrLn apiDocs

    let finalize = do
            putStr "creating checkpoint and shutting down acid-state..."
            createCheckpoint st
            closeAcidState st
            putStrLn " [ok]"

            putStr "shutting down hslogger..."
            removeAllHandlers
            putStrLn " [ok]"

    catch run (\ (e :: SomeException) -> finalize >> throw e)
    finalize

-- curl -H "Content-Type: application/json" -X PUT -d '{"userGroups":[],"userPassword":"dummy","userName":"dummy","userID":3,"userEmail":"dummy"}' -v http://localhost:8001/v0.0.1/user/id/3
-- curl -H "Content-Type: application/json" -X POST -d '{"userGroups":[],"userPassword":"dummy","userName":"dummy","userEmail":"dummy"}' -v http://localhost:8001/v0.0.1/user
