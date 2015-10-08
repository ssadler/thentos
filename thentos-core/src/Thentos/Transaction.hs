{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleContexts #-}

module Thentos.Transaction
where

import Control.Exception.Lifted (throwIO)
import Control.Lens ((^.))
import Control.Monad (void, when)
import Control.Monad.Except (throwError)
import Database.PostgreSQL.Simple         (Only(..))
import Database.PostgreSQL.Simple.Errors  (ConstraintViolation(UniqueViolation))
import Database.PostgreSQL.Simple.SqlQQ   (sql)
import Data.String.Conversions (ST)
import Data.Typeable (Typeable)

import Thentos.Types
import Thentos.Transaction.Core


-- * user

lookupConfirmedUser :: UserId -> ThentosQuery e (UserId, User)
lookupConfirmedUser uid = do
    users <- queryT [sql| SELECT name, password, email
                          FROM users
                          WHERE id = ? AND confirmed = true |] (Only uid)
    case users of
      [(name, pwd, email)] -> return (uid, User name pwd email)
      []                   -> throwError NoSuchUser
      _                    -> impossible "lookupConfirmedUser: multiple results"

-- | Lookup any user (whether confirmed or not) by their ID.
lookupAnyUser :: UserId -> ThentosQuery e (UserId, User)
lookupAnyUser uid = do
    users <- queryT [sql| SELECT name, password, email
                          FROM users
                          WHERE id = ? |] (Only uid)
    case users of
      [(name, pwd, email)] -> return (uid, User name pwd email)
      []                   -> throwError NoSuchUser
      _                    -> impossible "lookupAnyUser: multiple results"

lookupConfirmedUserByName :: UserName -> ThentosQuery e (UserId, User)
lookupConfirmedUserByName uname = do
    users <- queryT [sql| SELECT id, name, password, email
                          FROM users
                          WHERE name = ? AND confirmed = true |] (Only uname)
    case users of
      [(uid, name, pwd, email)] -> return (uid, User name pwd email)
      []                        -> throwError NoSuchUser
      _                         -> impossible "lookupConfirmedUserByName: multiple users"


lookupConfirmedUserByEmail :: UserEmail -> ThentosQuery e (UserId, User)
lookupConfirmedUserByEmail email = do
    users <- queryT [sql| SELECT id, name, password
                          FROM users
                          WHERE email = ? AND confirmed = true |] (Only email)
    case users of
      [(uid, name, pwd)] -> return (uid, User name pwd email)
      []                 -> throwError NoSuchUser
      _                  -> impossible "lookupConfirmedUserByEmail: multiple users"

-- | Lookup any user (whether confirmed or not) by their email address.
lookupAnyUserByEmail :: UserEmail -> ThentosQuery e (UserId, User)
lookupAnyUserByEmail email = do
    users <- queryT [sql| SELECT id, name, password
                          FROM users
                          WHERE email = ? |] (Only email)
    case users of
      [(uid, name, pwd)] -> return (uid, User name pwd email)
      []                 -> throwError NoSuchUser
      _                  -> impossible "lookupAnyUserByEmail: multiple users"


-- | Actually add a new user. The user may already have an ID, otherwise the DB will automatically
-- create one (auto-increment). NOTE that mixing calls with 'Just' an ID with those without
-- is a very bad idea and will quickly lead to errors!
addUserPrim :: Maybe UserId -> User -> Bool -> ThentosQuery e UserId
addUserPrim mUid user confirmed = do
    res <- queryT [sql| INSERT INTO users (id, name, password, email, confirmed)
                        VALUES (?, ?, ?, ?, ?)
                        RETURNING id |]
            (orDefault mUid, user ^. userName, user ^. userPassword, user ^. userEmail, confirmed)
    case res of
        [Only uid] -> return uid
        []         -> impossible "addUserPrim created user without ID"
        _          -> impossible "addUserPrim created multiple users"

-- | Add a new user and return the new user's 'UserId'.
-- Ensures that user name and email address are unique.
addUser :: (Show e, Typeable e) => User -> ThentosQuery e UserId
addUser user = addUserPrim Nothing user True

addUnconfirmedUserPrim :: ConfirmationToken -> User -> Maybe UserId -> ThentosQuery e UserId
addUnconfirmedUserPrim token user mUid = do
    uid <- addUserPrim mUid user False
    void $ execT [sql| INSERT INTO user_confirmation_tokens (id, token)
                       VALUES (?, ?) |] (uid, token)
    return uid

-- | Add a new unconfirmed user (i.e. one whose email address we haven't confirmed yet).
-- Ensures that user name and email address are unique.
addUnconfirmedUser :: (Show e, Typeable e) => ConfirmationToken -> User -> ThentosQuery e UserId
addUnconfirmedUser token user = addUnconfirmedUserPrim token user Nothing

-- | Add a new unconfirmed user, assigning a specific ID to the new user.
-- Ensures that ID, user name and email address are unique.
--
-- BE CAREFUL regarding the source of the specified user ID. If it comes from a backend context
-- (such as the A3 backend), it should be safe. But if a user/external API can provide it, that
-- would leak information about the (non-)existence of IDs in our db.
addUnconfirmedUserWithId :: ConfirmationToken -> User -> UserId -> ThentosQuery e ()
addUnconfirmedUserWithId token user uid = void $ addUnconfirmedUserPrim token user $ Just uid

finishUserRegistration :: Timeout -> ConfirmationToken -> ThentosQuery e UserId
finishUserRegistration timeout token = do
    res <- queryT [sql|
        UPDATE users SET confirmed = true
        FROM user_confirmation_tokens
        WHERE users.id = user_confirmation_tokens.id
            AND timestamp + ? > now()
            AND token = ?;

        DELETE FROM user_confirmation_tokens
        WHERE token = ? AND timestamp + ? > now()
        RETURNING id;
    |] (timeout, token, token, timeout)
    case res of
        [] -> throwError NoSuchToken
        [Only uid] -> return uid
        _ -> impossible "repeated user confirmation token"

-- | Confirm a user based on the 'UserId' rather than the 'ConfirmationToken.'
finishUserRegistrationById :: UserId -> ThentosQuery e ()
finishUserRegistrationById uid = do
    c <- execT [sql|
    UPDATE users SET confirmed = true WHERE id = ?;
    DELETE FROM user_confirmation_tokens WHERE id = ?;
    |] (uid, uid)
    case c of
        1 -> return ()
        0 -> throwError NoSuchPendingUserConfirmation
        _ -> impossible "finishUserRegistrationById: id uniqueness violation"

-- | Add a password reset token.  Return the user whose password this token can change.
addPasswordResetToken :: UserEmail -> PasswordResetToken -> ThentosQuery e User
addPasswordResetToken email token = do
    (uid, user) <- lookupAnyUserByEmail email
    void $ execT [sql| INSERT INTO password_reset_tokens (token, uid)
                VALUES (?, ?) |] (token, uid)
    return user

-- | Change a password with a given password reset token and remove the token.  Throw an error if
-- the token does not exist or has expired.
resetPassword :: Timeout -> PasswordResetToken -> HashedSecret UserPass -> ThentosQuery e ()
resetPassword timeout token newPassword = do
    modified <- execT [sql| UPDATE users
                            SET password = ?
                            FROM password_reset_tokens
                            WHERE password_reset_tokens.timestamp + ? > now()
                            AND users.id = password_reset_tokens.uid
                            AND password_reset_tokens.token = ?
                      |] (newPassword, timeout, token)
    case modified of
        1 -> return ()
        0 -> throwError NoSuchToken
        _ -> impossible "password reset token exists multiple times"

addUserEmailChangeRequest :: UserId -> UserEmail -> ConfirmationToken -> ThentosQuery e ()
addUserEmailChangeRequest uid newEmail token = do
    void $ execT [sql| INSERT INTO email_change_tokens (token, uid, new_email)
                VALUES (?, ?, ?) |] (token, uid, newEmail)

-- | Change email with a given token and remove the token.  Throw an error if the token does not
-- exist or has expired.
confirmUserEmailChange :: Timeout -> ConfirmationToken -> ThentosQuery e ()
confirmUserEmailChange timeout token = do
    modified <- execT [sql| UPDATE users
                            SET email = email_change_tokens.new_email
                            FROM email_change_tokens
                            WHERE timestamp + ? > now()
                            AND users.id = email_change_tokens.uid
                            AND email_change_tokens.token = ?
                      |] (timeout, token)
    case modified of
        1 -> return ()
        0 -> throwError NoSuchToken
        _ -> impossible "email change token exists multiple times"


-- | Change password. Should only be called once the old password has been
-- verified.
changePassword :: UserId -> HashedSecret UserPass -> ThentosQuery e ()
changePassword uid newpass = do
    modified <- q
    case modified of
        1 -> return ()
        0 -> throwError NoSuchUser
        _ -> impossible "changePassword: unique constraint on id violated"
  where
    q = execT [sql| UPDATE users SET password = ? WHERE id = ?  |] (newpass, uid)


-- | Delete user with given 'UserId'.  Throw an error if user does not exist.
deleteUser :: UserId -> ThentosQuery e ()
deleteUser uid
    = execT [sql| DELETE FROM users WHERE id = ? |] (Only uid) >>= \ x -> case x of
      1 -> return ()
      0 -> throwError NoSuchUser
      _ -> impossible "deleteUser: unique constraint on id violated"


-- * service

allServiceIds :: ThentosQuery e [ServiceId]
allServiceIds = map fromOnly <$> queryT [sql| SELECT id FROM services |] ()

lookupService :: ServiceId -> ThentosQuery e (ServiceId, Service)
lookupService sid = do
    services <- queryT [sql| SELECT key, owner_user, owner_service, name, description
                             FROM services
                             WHERE id = ? |] (Only sid)
    service <- case services of
        [(key, ownerU, ownerS, name, desc)] ->
            let owner = makeAgent ownerU ownerS
            in return $ Service key owner Nothing name desc
        []                         -> throwError NoSuchService
        _                          -> impossible "lookupService: multiple results"
    return (sid, service)

-- | Add new service.
addService ::
    Agent -> ServiceId -> HashedSecret ServiceKey -> ServiceName
    -> ServiceDescription -> ThentosQuery e ()
addService (UserA uid) sid secret name description = void $
    execT [sql| INSERT INTO services (id, owner_user, name, description, key)
                VALUES (?, ?, ?, ?, ?)
          |] (sid, uid, name, description, secret)
addService (ServiceA ownerSid) sid secret name description = void $
    execT [sql| INSERT INTO services (id, owner_service, name, description, key)
                VALUES (?, ?, ?, ?, ?)
          |] (sid, ownerSid, name, description, secret)

-- | Delete service with given 'ServiceId'.  Throw an error if service does not exist.
deleteService :: ServiceId -> ThentosQuery e ()
deleteService sid = do
    deletedCount <- execT [sql| DELETE FROM services
                                WHERE id = ? |] (Only sid)
    case deletedCount of
        0 -> throwError NoSuchService
        1 -> return ()
        _ -> impossible "deleteService: multiple results"

-- Register a user to grant them access to a service. Throws an error if the user is already
-- registered for the service.
registerUserWithService :: UserId -> ServiceId -> ServiceAccount -> ThentosQuery e ()
registerUserWithService uid sid (ServiceAccount anonymous) = void $
    execT [sql| INSERT INTO user_services (uid, sid, anonymous)
                VALUES (?, ?, ?) |] (uid, sid, anonymous)

-- Unregister a user from accessing a service. No-op if the user was not registered for the
-- service.
unregisterUserFromService :: UserId -> ServiceId -> ThentosQuery e ()
unregisterUserFromService uid sid = void $
    execT [sql| DELETE FROM user_services WHERE uid = ? AND sid = ? |] (uid, sid)


-- * persona and context

-- | Add a new persona to the DB. A persona has a unique name and a user to which it belongs.
-- The 'PersonaId' is assigned by the DB. May throw 'NoSuchUser' or 'PersonaNameAlreadyExists'.
addPersona :: ST -> UserId -> ThentosQuery e Persona
addPersona name uid = do
    res <- queryT [sql| INSERT INTO personas (name, uid) VALUES (?, ?) RETURNING id |]
                  (name, uid)
    case res of
        [Only persId] -> return $ Persona persId name uid
        _             -> impossible "addContext didn't return a single ID"

-- | Delete a persona. Throw 'NoSuchPersona' if the persona does not exist in the DB.
deletePersona :: PersonaId -> ThentosQuery e ()
deletePersona persId = do
    rows <- execT [sql| DELETE FROM personas WHERE id = ? |] (Only persId)
    case rows of
        1 -> return ()
        0 -> throwError NoSuchPersona
        _ -> impossible "deletePersona: unique constraint on id violated"

-- | Add a new context. The first argument identifies the service to which the context belongs.
-- May throw 'NoSuchService' or 'ContextNameAlreadyExists'.
addContext :: ServiceId -> ContextName -> ContextDescription -> ProxyUri -> ThentosQuery e Context
addContext ownerService name desc url = do
    res <- queryT [sql| INSERT INTO contexts (owner_service, name, description, url)
                        VALUES (?, ?, ?, ?)
                        RETURNING id |]
                  (ownerService, name, desc, url)
    case res of
        [Only cxtId] -> return $ Context cxtId ownerService name desc url
        _            -> impossible "addContext didn't return a single ID"

-- | Delete a context. Throw an error if the context does not exist in the DB.
deleteContext :: ContextId -> ThentosQuery e ()
deleteContext cxtId = do
    rows <- execT [sql| DELETE FROM contexts WHERE id = ? |] (Only cxtId)
    case rows of
        1 -> return ()
        0 -> throwError NoSuchContext
        _ -> impossible "deleteContext: unique constraint on id violated"

-- Connect a persona with a context. Throws an error if the persona is already registered for the
-- context or if the user has any *other* persona registered for the context. (As we currently
-- allow only one persona per user and context.)
registerPersonaWithContext :: Persona -> ContextId -> ThentosQuery e ()
registerPersonaWithContext persona cxtId = do
    -- Check that user has no registered personas yet
    res <- queryT [sql| SELECT count(*)
                        FROM personas pers, personas_per_context pc
                        WHERE pers.id = pc.persona_id AND pers.uid = ? AND pc.context_id = ? |]
                  (Only $ persona ^. personaUid)
    case res of
        [Only (count :: Int)] -> when (count > 0) . throwError $ MultiplePersonasPerContext
        _ -> impossible "registerPersonaWithContext: count didn't return a single result"
    void $ execT [sql| INSERT INTO personas_per_context (persona_id, context_id)
                       VALUES (?, ?) |] (persona ^. personaId, cxtId)

-- Unregister a persona from accessing a context. No-op if the persona was not registered for the
-- context.
unregisterPersonaFromContext :: PersonaId -> ContextId -> ThentosQuery e ()
unregisterPersonaFromContext persId cxtId = void $
    execT [sql| DELETE FROM personas_per_context WHERE persona_id = ? AND context_id = ? |]
          (persId, cxtId)

-- Find the persona that a user wants to use for a context (if any).
findPersona :: UserId -> ContextId -> ThentosQuery e (Maybe Persona)
findPersona uid cxtId = do
    res <- queryT [sql| SELECT pers.id, pers.name
                        FROM personas pers, personas_per_context pc
                        WHERE pers.id = pc.persona_id AND pers.uid = ? AND pc.context_id = ? |]
                  (uid, cxtId)
    case res of
        [(persId, name)] -> return . Just $ Persona persId name uid
        []               -> return Nothing
        -- This is not 'impossible', since the constraint is enforced by us, not by the DB
        _                -> error "findPersona: multiple personas per context"

-- List all contexts owned by a service.
contextsForService :: ServiceId -> ThentosQuery e [Context]
contextsForService sid = map mkContext <$>
    queryT [sql| SELECT id, name, description, url FROM contexts WHERE owner_service = ? |]
           (Only sid)
  where
    mkContext (cxtId, name, description, url) = Context cxtId sid name description url


-- * thentos and service session

-- | Lookup session.  If session does not exist or has expired, throw an error.  If it does exist,
-- bump the expiry time and return session with bumped expiry time.
lookupThentosSession ::
     ThentosSessionToken -> ThentosQuery e (ThentosSessionToken, ThentosSession)
lookupThentosSession token = do
    void $ execT [sql| UPDATE thentos_sessions
                       SET end_ = now()::timestamptz + period
                       WHERE token = ? AND end_ >= now()
                 |] (Only token)
    sesss <- queryT [sql| SELECT uid, sid, start, end_, period FROM thentos_sessions
                          WHERE token = ? AND end_ >= now()
                    |] (Only token)
    case sesss of
        [(uid, sid, start, end, period)] ->
            let agent = makeAgent uid sid
            in return ( token
                      , ThentosSession agent start end period
                      )
        []                          -> throwError NoSuchThentosSession
        _                           -> impossible "lookupThentosSession: multiple results"

-- | Start a new thentos session. Start time is set to now, end time is calculated based on the
-- specified 'Timeout'. If the agent is a user, this new session is added to their existing
-- sessions. Only confirmed users are allowed to log in; a 'NoSuchUser' error is thrown otherwise.
-- FIXME not implemented: If the agent is a service with an existing session, its session is
-- replaced.
startThentosSession :: ThentosSessionToken -> Agent -> Timeout -> ThentosQuery e ()
startThentosSession tok (UserA uid) period = do
    void $ lookupConfirmedUser uid  -- may throw NoSuchUser
    void $ execT [sql| INSERT INTO thentos_sessions (token, uid, start, end_, period)
                       VALUES (?, ?, now(), now() + ?, ?)
                 |] (tok, uid, period, period)
startThentosSession tok (ServiceA sid) period = void $ execT
    [sql| INSERT INTO thentos_sessions (token, sid, start, end_, period)
          VALUES (?, ?, now(), now() + ?, ?)|]
            (tok, sid, period, period)

-- | End thentos session and all associated service sessions.
-- If thentos session does not exist or has expired, remove it just the same.
--
-- Always call this transaction if you want to clean up a session (e.g., from a garbage collection
-- transaction).  This way in the future, you can replace this transaction easily by one that does
-- not actually destroy the session, but move it to an archive.
endThentosSession :: ThentosSessionToken -> ThentosQuery e ()
endThentosSession tok =
    void $ execT [sql| DELETE FROM thentos_sessions WHERE token = ?
                 |] (Only tok)

-- | Get the names of all services that a given thentos session is signed into
serviceNamesFromThentosSession :: ThentosSessionToken -> ThentosQuery e [ServiceName]
serviceNamesFromThentosSession tok = do
    res <- queryT
        [sql| SELECT services.name
              FROM services, service_sessions
              WHERE services.id = service_sessions.service
                  AND service_sessions.thentos_session_token = ? |] (Only tok)
    return $ map fromOnly res


-- | Like 'lookupThentosSession', but for 'ServiceSession'.  Bump both service and associated
-- thentos session.  If the service session is still active, but the associated thentos session has
-- expired, update service sessions expiry time to @now@ and throw 'NoSuchThentosSession'.
lookupServiceSession :: ServiceSessionToken -> ThentosQuery e (ServiceSessionToken, ServiceSession)
lookupServiceSession token = do
    sessions <- queryT
        [sql| SELECT service, start, end_, period, thentos_session_token, meta
              FROM service_sessions
              WHERE token = ? |] (Only token)
    case sessions of
        []        -> throwError NoSuchServiceSession
        [(service, start, end, period, thentosSessionToken, meta)] ->
            return (token, ServiceSession service start end period thentosSessionToken meta)
        _         -> impossible "multiple sessions with the same token"

-- | Like 'startThentosSession' for service sessions.  Bump associated thentos session.  Throw an
-- error if thentos session lookup fails.  If a service session already exists for the given
-- 'ServiceId', return its token.
startServiceSession ::
    ThentosSessionToken -> ServiceSessionToken -> ServiceId
    -> Timeout -> ThentosQuery e ()
startServiceSession thentosSessionToken token sid timeout =
    void $ execT [sql| INSERT INTO service_sessions
                        (token, thentos_session_token, start, end_, period, service, meta)
                       VALUES (?, ?, now(), now() + ?, ?, ?,
                            (SELECT users.name FROM users, thentos_sessions WHERE
                             users.id = thentos_sessions.uid
                                AND thentos_sessions.token = ?)
                            ) |]
                (token, thentosSessionToken, timeout, timeout, sid, thentosSessionToken)

-- | Like 'endThentosSession' for service sessions (see there).  If thentos session or service
-- session do not exist or have expired, remove the service session just the same, but never thentos
-- session.
endServiceSession :: ServiceSessionToken -> ThentosQuery e ()
endServiceSession token = do
    deleted <- execT
        [sql| DELETE FROM service_sessions WHERE token = ? |] (Only token)
    case deleted of
        0 -> throwError NoSuchServiceSession
        1 -> return ()
        _ -> impossible "multiple service sessions with same token"


-- * agents, roles, and groups

-- | Add a new role to the roles defined for an 'Agent'.  If 'Role' is already assigned to
-- 'Agent', do nothing.
assignRole :: Agent -> Role -> ThentosQuery e ()
assignRole agent role = case agent of
    ServiceA sid -> catchViolation catcher' $
        void $ execT [sql| INSERT INTO service_roles (sid, role)
                           VALUES (?, ?) |] (sid, role)
    UserA uid  -> do
        catchViolation catcher' $ void $
            execT [sql| INSERT INTO user_roles (uid, role)
                        VALUES (?, ?) |] (uid, role)
  where
    catcher' _ (UniqueViolation "user_roles_uid_role_key") = return ()
    catcher' _ (UniqueViolation "service_roles_sid_role_key") = return ()
    catcher' e _                                           = throwIO e

-- | Remove a 'Role' from the roles defined for an 'Agent'.  If 'Role' is not assigned to 'Agent',
-- do nothing.
unassignRole :: Agent -> Role -> ThentosQuery e ()
unassignRole agent role = case agent of
    ServiceA sid -> void $ execT
        [sql| DELETE FROM service_roles WHERE sid = ? AND role = ? |] (sid, role)
    UserA uid  -> do
        void $ execT [sql| DELETE FROM user_roles WHERE uid = ? AND role = ? |]
                           (uid, role)

-- | All 'Role's of an 'Agent'.  If 'Agent' does not exist or has no roles, return an empty list.
agentRoles :: Agent -> ThentosQuery e [Role]
agentRoles agent = case agent of
    ServiceA sid -> do
        roles <- queryT [sql| SELECT role FROM service_roles WHERE sid = ? |]
                        (Only sid)
        return $ map fromOnly roles
    UserA uid  -> do
        roles <- queryT [sql| SELECT role FROM user_roles WHERE uid = ? |] (Only uid)
        return $ map fromOnly roles


-- * garbage collection

-- | Go through "thentos_sessions" table and find all expired sessions.
garbageCollectThentosSessions :: ThentosQuery e ()
garbageCollectThentosSessions = void $ execT [sql|
    DELETE FROM thentos_sessions WHERE end_ < now()
    |] ()

garbageCollectServiceSessions :: ThentosQuery e ()
garbageCollectServiceSessions = void $ execT [sql|
    DELETE FROM service_sessions WHERE end_ < now()
    |] ()

-- | Remove all expired unconfirmed users from db.
garbageCollectUnconfirmedUsers :: Timeout -> ThentosQuery e ()
garbageCollectUnconfirmedUsers timeout = void $ execT [sql|
    DELETE FROM "users" WHERE created < now() - ?::interval AND confirmed = false;
    |] (Only timeout)

-- | Remove all expired password reset requests from db.
garbageCollectPasswordResetTokens :: Timeout -> ThentosQuery e ()
garbageCollectPasswordResetTokens timeout = void $ execT [sql|
    DELETE FROM "password_reset_tokens" WHERE timestamp < now() - ?::interval;
    |] (Only timeout)

-- | Remove all expired email change requests from db.
garbageCollectEmailChangeTokens :: Timeout -> ThentosQuery e ()
garbageCollectEmailChangeTokens timeout = void $ execT [sql|
    DELETE FROM "email_change_tokens" WHERE timestamp < now() - ?::interval;
    |] (Only timeout)


-- * helpers

-- | Throw an error from a situation which (we believe) will never arise.
impossible :: String -> a
impossible msg = error $ "Impossible error: " ++ msg

-- | Given either a UserId or a ServiceId, return an Agent.  Throws an error if not exactly one of
-- the arguments is 'Just' (totality enforced by constraint on `services.owner_{user,service}`).
-- Useful for getting an Agent from the database.
makeAgent :: Maybe UserId -> Maybe ServiceId -> Agent
makeAgent (Just uid) Nothing  = UserA uid
makeAgent Nothing (Just sid) = ServiceA sid
makeAgent _ _ = impossible "makeAgent: invalid arguments"
