{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE ScopedTypeVariables  #-}

module Thentos.ActionSpec where

import Control.Lens ((.~), (^.))
import Control.Monad (void)
import Data.Either (isLeft, isRight)
import LIO.DCLabel ((%%))
import Test.Hspec (Spec, SpecWith, describe, it, before, after, shouldBe, shouldSatisfy, hspec)

import LIO.Missing
import Test.Arbitrary ()
import Test.Config
import Test.Core
import Test.Types
import Thentos.Action
import Thentos.Action.Core
import Thentos.Types

import qualified Thentos.Transaction as T  -- FIXME: this shouldn't be here.


tests :: IO ()
tests = hspec spec

spec :: Spec
spec = describe "Thentos.Action" . before setupDB . after teardownDB $ do
    spec_user
    spec_service
    spec_agentsAndRoles
    spec_session


spec_user :: SpecWith DBTS
spec_user = describe "user" $ do
    describe "addUser, lookupUser, deleteUser" $ do
        it "works" $ \(DBTS _ sta) -> do
            let user = testUsers !! 0
            uid <- runActionWithPrivs [RoleAdmin] sta $ addUser (head testUserForms)
            (uid', user') <- runActionWithPrivs [RoleAdmin] sta $ lookupUser uid
            uid' `shouldBe` uid
            user' `shouldBe` (userPassword .~ (user' ^. userPassword) $ user)
            void . runActionWithPrivs [RoleAdmin] sta $ deleteUser uid
            Left (ActionErrorThentos NoSuchUser) <-
                runActionWithClearanceE dcBottom sta $ lookupUser uid
            return ()

        it "guarantee that user names are unique" $ \ (DBTS _ sta) -> do
            (_, _, user) <- runActionWithClearance dcBottom sta $ addTestUser 1
            let userFormData = UserFormData (user ^. userName)
                                            (UserPass "foo")
                                            (forceUserEmail "new@one.com")
            Left (ActionErrorThentos e) <- runActionWithPrivsE [RoleAdmin] sta $
                addUser userFormData
            e `shouldBe` UserNameAlreadyExists

        it "guarantee that user email addresses are unique" $ \(DBTS _ sta) -> do
            (_, _, user) <- runActionWithClearance dcBottom sta $ addTestUser 1
            let userFormData = UserFormData (UserName "newOne")
                                            (UserPass "foo")
                                            (user ^. userEmail)
            Left (ActionErrorThentos e) <- runActionWithPrivsE [RoleAdmin] sta $ addUser userFormData
            e `shouldBe` UserEmailAlreadyExists

{-
    -- FIXME: there doesn't seem to be a corresponding action for AddUsers yet
    describe "AddUsers" $ do
        it "works" $ \ (DBTS _ (ActionState (st, _, _))) -> do
            result <- update' st $ T.AddUsers ((testUsers !!) <$> [2..4])
            result `shouldBe` Right (UserId <$> [1..3])

        it "rolls back in case of error (adds all or nothing)" $ \ (DBTS _ (ActionState (st, _, _))) -> do
            _ <- update' st $ T.AddUser (testUsers !! 4)
            Left UserNameAlreadyExists <- update' st $ T.AddUsers ((testUsers !!) <$> [2..4])
            result <- query' st $ T.AllUserIds
            result `shouldBe` Right (UserId <$> [0..1])
-}

    describe "DeleteUser" $ do
        it "user can delete herself, even if not admin" $ \(DBTS _ sta) -> do
            (uid, _, _) <- runActionWithClearance dcBottom sta $ addTestUser 3
            result <- runActionWithPrivsE [UserA uid] sta $ deleteUser uid
            result `shouldSatisfy` isRight

        it "nobody else but the deleted user and admin can do this" $ \ (DBTS _ sta) -> do
            (uid,  _, _) <- runActionWithClearance dcBottom sta $ addTestUser 3
            (uid', _, _) <- runActionWithClearance dcBottom sta $ addTestUser 4
            result <- runActionWithPrivsE [UserA uid] sta $ deleteUser uid'
            result `shouldSatisfy` isLeft

    describe "UpdateUser" $ do
        it "changes user if it exists" $ \(DBTS _ sta) -> do
            (uid, _, user) <- runActionWithClearance dcBottom sta $ addTestUser 1
            runActionWithPrivs [UserA uid] sta $ updateUserField uid (T.UpdateUserFieldName "fka_user1")

            result <- runActionWithPrivs [UserA uid] sta $ lookupUser uid
            result `shouldBe` (UserId 1, userName .~ "fka_user1" $ user)

        it "throws an error if user does not exist" $ \(DBTS _ sta) -> do
            Left (ActionErrorThentos e) <- runActionWithPrivsE [RoleAdmin] sta $ updateUserField (UserId 391) (T.UpdateUserFieldName "moo")
            e `shouldBe` NoSuchUser

    describe "checkPassword" $ do
        it "works" $ \(DBTS _ sta) -> do
            void . runAction sta $ startThentosSessionByUserId godUid godPass
            void . runAction sta $ startThentosSessionByUserName godName godPass


spec_service :: SpecWith DBTS
spec_service = describe "service" $ do
    describe "addService, lookupService, deleteService" $ do
        it "works" $ \(DBTS _ sta) -> do
            let addsvc name desc = runActionWithClearanceE (UserA godUid %% UserA godUid) sta $ addService (UserA (UserId 0)) name desc
            Right (service1_id, _s1_key) <- addsvc "fake name" "fake description"
            Right (service2_id, _s2_key) <- addsvc "different name" "different description"
            service1 <- runActionWithPrivs [RoleAdmin] sta $ lookupService service1_id
            service2 <- runActionWithPrivs [RoleAdmin] sta $ lookupService service2_id
            service1 `shouldBe` service1 -- sanity check for reflexivity of Eq
            service1 `shouldSatisfy` (/= service2) -- should have different keys
            void . runActionWithPrivs [RoleAdmin] sta $ deleteService service1_id
            Left (ActionErrorThentos NoSuchService) <-
                runActionWithPrivsE [RoleAdmin] sta $ lookupService service1_id
            return ()


spec_agentsAndRoles :: SpecWith DBTS
spec_agentsAndRoles = describe "agentsAndRoles" $ do
    describe "agents and roles" $ do
        describe "assign" $ do
            it "can be called by admins" $ \ (DBTS _ sta) -> do
                (UserA -> targetAgent, _, _) <- runActionWithClearance dcBottom sta $ addTestUser 1
                result <- runActionWithPrivsE [RoleAdmin] sta $ assignRole targetAgent (RoleBasic RoleAdmin)
                result `shouldSatisfy` isRight

            it "can NOT be called by any non-admin agents" $ \ (DBTS _ sta) -> do
                let targetAgent = UserA $ UserId 1
                result <- runActionWithPrivsE [targetAgent] sta $ assignRole targetAgent (RoleBasic RoleAdmin)
                result `shouldSatisfy` isLeft

        describe "lookup" $ do
            it "can be called by admins" $ \ (DBTS _ sta) -> do
                let targetAgent = UserA $ UserId 1
                result <- runActionWithPrivsE [RoleAdmin] sta $ agentRoles targetAgent
                result `shouldSatisfy` isRight

            it "can be called by user for her own roles" $ \ (DBTS _ sta) -> do
                let targetAgent = UserA $ UserId 1
                result <- runActionWithPrivsE [targetAgent] sta $ agentRoles targetAgent
                result `shouldSatisfy` isRight

            it "can NOT be called by other users" $ \ (DBTS _ sta) -> do
                let targetAgent = UserA $ UserId 1
                    askingAgent = UserA $ UserId 2
                result <- runActionWithPrivsE [askingAgent] sta $ agentRoles targetAgent
                result `shouldSatisfy` isLeft


spec_session :: SpecWith DBTS
spec_session = describe "session" $ do
    describe "StartSession" $ do
        it "works" $ \ (DBTS _ sta) -> do
            result <- runActionE sta $ startThentosSessionByUserName godName godPass
            result `shouldSatisfy` isRight
            return ()

    describe "lookupThentosSession" $ do
        it "works" $ \ (DBTS _ astate :: DBTS) -> do
            ((ernieId, ernieF, _) : (bertId, _, _) : _)
                <- runActionWithClearance dcTop astate initializeTestUsers

            tok <- runActionWithClearance dcTop astate $
                    startThentosSessionByUserId ernieId (udPassword ernieF)
            v1 <- runActionAsAgent (UserA ernieId) astate (existsThentosSession tok)
            v2 <- runActionAsAgent (UserA bertId)  astate (existsThentosSession tok)

            runActionWithClearance dcTop astate $ endThentosSession tok
            v3 <- runActionAsAgent (UserA ernieId) astate (existsThentosSession tok)
            v4 <- runActionAsAgent (UserA bertId)  astate (existsThentosSession tok)

            (v1, v2, v3, v4) `shouldBe` (True, False, False, False)
