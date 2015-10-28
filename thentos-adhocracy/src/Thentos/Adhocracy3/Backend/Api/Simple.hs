{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- | This is an implementation of
-- git@github.com:liqd/adhocracy3.git:/docs/source/api/authentication_api.rst
module Thentos.Adhocracy3.Backend.Api.Simple
    ( A3Resource(..)
    , A3UserNoPass(..)
    , A3UserWithPass(..)
    , ActivationRequest(..)
    , Api
    , ContentType(..)
    , LoginRequest(..)
    , PasswordResetRequest(..)
    , Path(..)
    , RequestResult(..)
    , ThentosApi
    , TypedPath(..)
    , TypedPathWithCacheControl(..)
    , a3corsPolicy
    , a3ProxyAdapter
    , runBackend
    , serveApi
    , thentosApi
    ) where

import Control.Lens ((^.))
import Control.Monad.Except (MonadError, throwError)
import Control.Monad (when, mzero)
import Data.Aeson (FromJSON(parseJSON), ToJSON(toJSON), Value(Object), (.:), (.:?), (.=), object,
                   withObject)

import Data.CaseInsensitive (mk)
import Data.Configifier ((>>.), Tagged(Tagged))
import Data.Functor.Infix ((<$$>))
import Data.List (dropWhileEnd, stripPrefix)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (LBS, SBS, ST, cs)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import LIO.Core (liftLIO)
import LIO.TCB (ioTCB)
import Network.Wai (Application)
import Safe (readMay)
import Servant.API ((:<|>)((:<|>)), (:>), ReqBody, JSON)
import Servant.Server.Internal (Server)
import Servant.Server (serve, enter)
import System.Log (Priority(DEBUG, INFO))
import Text.Hastache (MuType(MuVariable))
import Text.Hastache.Context (mkStrContext)
import Text.Printf (printf)

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as ST
import qualified Network.HTTP.Client as Client
import qualified Network.HTTP.Types.Status as Status
import qualified URI.ByteString as URI

import System.Log.Missing
import Thentos.Adhocracy3.Backend.Core
import Thentos.Adhocracy3.Types
import Thentos.Backend.Api.Proxy
import Thentos.Backend.Core
import Thentos.Config
import Thentos.Util

import qualified Thentos.Action as A
import qualified Thentos.Action.Core as AC


-- * data types

-- ** basics

newtype Path = Path { fromPath :: ST }
  deriving (Eq, Ord, Show, Read, Typeable, Generic, FromJSON, ToJSON)

data ContentType = CTUser
  deriving (Eq, Ord, Enum, Bounded, Typeable, Generic)

instance Show ContentType where
    show CTUser = "adhocracy_core.resources.principal.IUser"

instance Read ContentType where
    readsPrec = readsPrecEnumBoundedShow

instance ToJSON ContentType where
    toJSON = Aeson.String . cs . show

instance FromJSON ContentType where
    parseJSON = Aeson.withText "content type string" $ maybe (fail "invalid content type") return . readMay . cs

data PropertySheet =
      PSUserBasic
    | PSUserExtended
    | PSPasswordAuthentication
  deriving (Eq, Enum, Bounded, Typeable)

instance Show PropertySheet where
    show PSUserBasic              = "adhocracy_core.sheets.principal.IUserBasic"
    show PSUserExtended           = "adhocracy_core.sheets.principal.IUserExtended"
    show PSPasswordAuthentication = "adhocracy_core.sheets.principal.IPasswordAuthentication"

instance Read PropertySheet where
    readsPrec = readsPrecEnumBoundedShow


-- ** resource

data A3Resource a = A3Resource
  { mPath :: Maybe Path
  , mContentType :: Maybe ContentType
  , mData :: Maybe a
  } deriving (Eq, Show, Typeable, Generic)

instance ToJSON a => ToJSON (A3Resource a) where
    toJSON (A3Resource p ct r) =
        object $ "path" .= p : "content_type" .= ct : case Aeson.toJSON <$> r of
            Just (Object v) -> HashMap.toList v
            Nothing -> []
            Just _ -> []

instance FromJSON a => FromJSON (A3Resource a) where
    parseJSON = withObject "resource object" $ \v -> A3Resource
        <$> (v .:? "path")
        <*> (v .:? "content_type")
        <*> (v .:? "data")

-- | Similar to A3Resource, but tailored for cases where @path@ and @content_type@ are present and
-- @data@ is absent (or irrelevant).
data TypedPath = TypedPath
  { tpPath :: Path
  , tpContentType :: ContentType
  } deriving (Eq, Show, Generic)

instance ToJSON TypedPath where
    toJSON (TypedPath p ct) = object ["path" .= p, "content_type" .= ct]

instance FromJSON TypedPath where
    parseJSON = withObject "resource object" $ \v -> TypedPath
        <$> (v .: "path") <*> (v .: "content_type")

-- | The A3 backend replies to POST request not just with a typed path, but also sends a listing
-- of created/modified etc. resources along to allow the A3 frontend to update its cache.
data TypedPathWithCacheControl = TypedPathWithCacheControl
    { tpccTypedPath :: TypedPath
    , tpccChangedDescendants :: [Path]
    , tpccCreated :: [Path]
    , tpccModified :: [Path]
    , tpccRemoved :: [Path]
    } deriving (Eq, Show, Generic)

instance ToJSON TypedPathWithCacheControl where
    toJSON t = object
        [ "path"              .= tpPath (tpccTypedPath t)
        , "content_type"      .= tpContentType (tpccTypedPath t)
        , "updated_resources" .= object
            [ "changed_descendants" .= tpccChangedDescendants t
            , "created"             .= tpccCreated t
            , "modified"            .= tpccModified t
            , "removed"             .= tpccRemoved t
            ]
        ]

-- ** individual resources

newtype A3UserNoPass = A3UserNoPass { fromA3UserNoPass :: UserFormData }
  deriving (Eq, Typeable, Generic)

newtype A3UserWithPass = A3UserWithPass { fromA3UserWithPass :: UserFormData }
  deriving (Eq, Typeable, Generic)

instance ToJSON A3UserNoPass where
    toJSON (A3UserNoPass user) = a3UserToJSON False user

instance ToJSON A3UserWithPass where
    toJSON (A3UserWithPass user) = a3UserToJSON True user

instance FromJSON A3UserNoPass where
    parseJSON value = A3UserNoPass <$> a3UserFromJSON False value

instance FromJSON A3UserWithPass where
    parseJSON value = A3UserWithPass <$> a3UserFromJSON True value

a3UserToJSON :: Bool -> UserFormData -> Aeson.Value
a3UserToJSON withPass (UserFormData name password email) = object
    [ "content_type" .= CTUser
    , "data" .= object (catMaybes
        [ Just $ cshow PSUserBasic .= object
            [ "name" .= name
            ]
        , Just $ cshow PSUserExtended .= object
            [ "email" .= email
            ]
        , if withPass
            then Just $ cshow PSPasswordAuthentication .= object ["password" .= password]
            else Nothing
        ])
    ]

a3UserFromJSON :: Bool -> Aeson.Value -> Aeson.Parser UserFormData
a3UserFromJSON withPass = withObject "resource object" $ \v -> do
    content_type :: ContentType <- v .: "content_type"
    when (content_type /= CTUser) $
        fail $ "wrong content type: " ++ show content_type
    name     <- v .: "data" >>= (.: cshow PSUserBasic) >>= (.: "name")
    email    <- v .: "data" >>= (.: cshow PSUserExtended) >>= (.: "email")
    password <- if withPass
        then v .: "data" >>= (.: cshow PSPasswordAuthentication) >>= (.: "password")
        else pure ""
    failOnError $ userNameValid name
    when withPass . failOnError $ passwordAcceptable password
    return $ UserFormData (UserName name) (UserPass password) email

-- | Fail if the argument is 'Just' an error. Do nothing otherwise.
failOnError :: Monad m => Maybe String -> m ()
failOnError = maybe (return ()) fail

-- | Check constraints on user name: The "name" field in the "IUserBasic"
-- schema is a non-empty string that can contain any characters except
-- '@' (to make user names distinguishable from email addresses). The
-- username must not contain any whitespace except single spaces,
-- preceded and followed by non-whitespace (no whitespace at begin or
-- end, multiple subsequent spaces are forbidden, tabs and newlines
-- are forbidden).
-- Returns 'Nothing' on success, otherwise 'Just' an error message.
userNameValid :: ST -> Maybe String
userNameValid name
  | ST.null name           = Just "user name is empty"
  | ST.any (== '@') name   = Just $ "'@' in user name is not allowed: "  ++ show name
  | normalizedName /= name = Just $ "Illegal whitespace sequence in user name: "  ++ show name
  | otherwise              = Nothing
  where normalizedName = ST.unwords . ST.words $ name

-- | Check constraints on password: It must have between 6 and 100 chars.
-- Returns 'Nothing' on success, otherwise 'Just' an error message.
passwordAcceptable :: ST -> Maybe String
passwordAcceptable pass
  | len < 6   = Just "password too short (less than 6 characters)"
  | len > 100 = Just "password too long (more than 100 characters)"
  | otherwise = Nothing
  where len = ST.length pass


-- ** other types

data ActivationRequest =
    ActivationRequest ConfirmationToken
  deriving (Eq, Show, Typeable, Generic)

data LoginRequest =
    LoginByName UserName UserPass
  | LoginByEmail UserEmail UserPass
  deriving (Eq, Typeable, Generic)

data PasswordResetRequest =
    PasswordResetRequest Path UserPass
  deriving (Eq, Typeable, Generic)

-- | Reponse to a login or similar request.
--
-- Note: this generic form is useful for parsing a result from A3, but you should never *return* a
-- 'RequestError' because then the status code won't be set correctly. Instead, throw a
-- 'GenericA3Error' or, even better, define and throw a custom error.
data RequestResult =
    RequestSuccess Path ThentosSessionToken
  | RequestError A3ErrorMessage
  deriving (Eq, Show, Typeable, Generic)

instance ToJSON ActivationRequest where
    toJSON (ActivationRequest (ConfirmationToken confToken)) =
        object ["path" .= ("/activate/" <> confToken)]

instance FromJSON ActivationRequest where
    parseJSON = withObject "activation request" $ \v -> do
        p :: ST <- v .: "path"
        case ST.stripPrefix "/activate/" p of
            Just confToken -> return . ActivationRequest . ConfirmationToken $ confToken
            Nothing        -> fail $ "ActivationRequest with malformed path: " ++ show p

instance ToJSON LoginRequest where
    toJSON (LoginByName  n p) = object ["name"  .= n, "password" .= p]
    toJSON (LoginByEmail e p) = object ["email" .= e, "password" .= p]

instance FromJSON LoginRequest where
    parseJSON = withObject "login request" $ \v -> do
        name <- UserName  <$$> v .:? "name"
        email <- v .:? "email"
        pass <- UserPass  <$>  v .: "password"
        case (name, email) of
          (Just x,  Nothing) -> return $ LoginByName x pass
          (Nothing, Just x)  -> return $ LoginByEmail x pass
          (_,       _)       -> fail $ "malformed login request body: " ++ show v

instance ToJSON PasswordResetRequest where
    toJSON (PasswordResetRequest path pass) = object ["path" .= path, "password" .= pass]

instance FromJSON PasswordResetRequest where
    parseJSON = withObject "password reset request" $ \v -> do
        path <- Path <$> v .: "path"
        pass <- v .: "password"
        failOnError $ passwordAcceptable pass
        return $ PasswordResetRequest path $ UserPass pass

instance ToJSON RequestResult where
    toJSON (RequestSuccess p t) = object $
        "status" .= ("success" :: ST) :
        "user_path" .= p :
        "user_token" .= t :
        []
    toJSON (RequestError errMsg) = toJSON errMsg

instance FromJSON RequestResult where
    parseJSON = withObject "request result" $ \v -> do
        n :: ST <- v .: "status"
        case n of
            "success" -> RequestSuccess <$> v .: "user_path" <*> v .: "user_token"
            "error" -> RequestError <$> parseJSON (Object v)
            _ -> mzero


-- * main

runBackend :: HttpConfig -> AC.ActionState -> IO ()
runBackend cfg asg = do
    logger INFO $ "running rest api (a3 style) on " ++ show (bindUrl cfg) ++ "."
    manager <- Client.newManager Client.defaultManagerSettings
    runWarpWithCfg cfg $ serveApi manager asg

serveApi :: Client.Manager -> AC.ActionState -> Application
serveApi manager = addCorsHeaders a3corsPolicy . addCacheControlHeaders . serve (Proxy :: Proxy Api) . api manager


-- * api

-- | Note: login_username and login_email have identical behavior.  In
-- particular, it is not an error to send username and password to
-- @/login_email@.  This makes implementing all sides of the protocol
-- a lot easier without sacrificing security.
type ThentosApi =
       "principals" :> "users" :> ReqBody '[JSON] A3UserWithPass
                               :> Post200 '[JSON] TypedPathWithCacheControl
  :<|> "activate_account"      :> ReqBody '[JSON] ActivationRequest :> Post200 '[JSON] RequestResult
  :<|> "login_username"        :> ReqBody '[JSON] LoginRequest :> Post200 '[JSON] RequestResult
  :<|> "login_email"           :> ReqBody '[JSON] LoginRequest :> Post200 '[JSON] RequestResult
  :<|> "password_reset"        :> ReqBody '[JSON] PasswordResetRequest :> Post200 '[JSON] RequestResult

type Api =
       ThentosApi
  :<|> ServiceProxy

thentosApi :: AC.ActionState -> Server ThentosApi
thentosApi actionState = enter (enterAction actionState a3ActionErrorToServantErr Nothing) $
       addUser
  :<|> activate
  :<|> login
  :<|> login
  :<|> resetPassword

api :: Client.Manager -> AC.ActionState -> Server Api
api manager actionState =
       thentosApi actionState
  :<|> serviceProxy manager a3ProxyAdapter actionState


-- * handler

-- | Add a user in Thentos, but not yet in A3. Only after the Thentos user has been activated
-- (confirmed), a corresponding persona is created in A3, which, from A3's viewpoint, is a user.
addUser :: A3UserWithPass -> A3Action TypedPathWithCacheControl
addUser (A3UserWithPass user) = AC.logIfError'P $ do
    AC.logger'P DEBUG . ("route addUser: " <>) . cs . Aeson.encodePretty $ A3UserNoPass user
    confToken <- snd <$> A.addUnconfirmedUser user
    config    <- AC.getConfig'P
    sendUserConfirmationMail config user confToken
    -- FIXME Which path should we return here, considering that no A3 user exists yet?!
    let dummyPath = a3backendPath config ""
    return $ TypedPathWithCacheControl (TypedPath dummyPath CTUser) [] [] [] []
    -- FIXME We correctly return empty cache-control info since the A3 DB isn't (yet) changed,
    -- but normally the A3 backend would return the following info if a new user is created:
    -- changedDescendants: "", "principals/", "principals/users/", "principals/groups/"
    -- created: userPath
    -- modified: "principals/users/", "principals/groups/authenticated/"
    -- Find out if not returning this stuff leads to problems in the A3 frontend!

-- | Activate a new user. This also creates a persona with the same name in the A3 backend,
-- so that the user is able to log into A3. The user's actual password and email address are
-- only stored in Thentos and NOT exposed to A3.
activate :: ActivationRequest -> A3Action RequestResult
activate ar@(ActivationRequest confToken) = AC.logIfError'P $ do
    AC.logger'P DEBUG . ("route activate:" <>) . cs $ Aeson.encodePretty ar
    (uid, stok) <- A.confirmNewUser confToken
    -- TODO Promote access right to run as that user
    user    <- snd <$> A.lookupConfirmedUser uid
    persona <- A.addPersona (PersonaName . fromUserName $ user ^. userName) uid
    path    <- createUserInA3'P persona
    -- TODO store mapping between personaId and path
    pure $ RequestSuccess path stok

-- | Log a user in.
-- TODO use mapping between personaId and path to find the user to login;
-- likewise when forwarding request headers
login :: LoginRequest -> A3Action RequestResult
login r = AC.logIfError'P $ do
    AC.logger'P DEBUG "/login/"
    config <- AC.getConfig'P
    (uid, stok) <- case r of
        LoginByName  uname pass -> A.startThentosSessionByUserName uname pass
        LoginByEmail email pass -> A.startThentosSessionByUserEmail email pass
    return $ RequestSuccess (userIdToPath config uid) stok

-- | Allow a user to reset their password. This endpoint is called by the A3 frontend after the user
-- has clicked on the link in a reset-password mail sent by the A3 backend. To check whether the
-- reset path is valid, we forward the request to the backend, but replacing the new password by a
-- dummy (as usual). If the backend indicates success, we update the password in Thentos.
-- A successful password reset will activate not-yet-activated users, as per the A3 API spec.
-- TODO adapt
-- TODO Before changing the password, try to activate the user in case they weren't yet activated.
resetPassword :: PasswordResetRequest -> A3Action RequestResult
resetPassword (PasswordResetRequest path pass) = AC.logIfError'P $ do
    AC.logger'P DEBUG $ "route password_reset for path: " <> show path
    reqResult <- resetPasswordInA3'P path
    case reqResult of
        RequestSuccess userPath _a3tok -> do
            uid  <- userIdFromPath userPath
            A._changePasswordUnconditionally uid pass
            stok <- A.startThentosSessionByUserId uid pass
            return $ RequestSuccess userPath stok
        RequestError errMsg            -> throwError . OtherError $ GenericA3Error errMsg


-- * helper actions

sendUserConfirmationMail :: ThentosConfig -> UserFormData -> ConfirmationToken -> A3Action ()
sendUserConfirmationMail cfg user (ConfirmationToken confToken) = do
    let smtpCfg :: SmtpConfig = Tagged $ cfg >>. (Proxy :: Proxy '["smtp"])
        accountVerificationCfg :: AccountVerificationConfig = Tagged $ cfg
            >>. (Proxy :: Proxy '["mail", "account_verification"])
        subject      = accountVerificationCfg >>. (Proxy :: Proxy '["subject"])
        bodyTemplate = accountVerificationCfg >>. (Proxy :: Proxy '["body"])
    body <- AC.renderTextTemplate'P bodyTemplate (mkStrContext context)
    AC.sendMail'P smtpCfg (Just $ udName user) (udEmail user) subject $ cs body
  where
    context "user_name"      = MuVariable . fromUserName $ udName user
    context "activation_url" = MuVariable $ (exposeUrl feHttp) <//> "/activate/" <//> confToken
    context _                = error "sendUserConfirmationMail: no such context"
    feHttp      = case cfg >>. (Proxy :: Proxy '["frontend"]) of
                      Nothing -> error "sendUserConfirmationMail: frontend not configured!"
                      Just v -> Tagged v

-- | Create a user in A3 from a persona and return the user path.
createUserInA3'P :: Persona -> A3Action Path
createUserInA3'P persona = do
    config <- AC.getConfig'P
    let a3req = fromMaybe
                (error "createUserInA3'P: mkUserCreationRequestForA3 failed, check config!") $
                mkUserCreationRequestForA3 config persona
    a3resp <- liftLIO . ioTCB . sendRequest $ a3req
    when (responseCode a3resp >= 400) $ do
        throwError . OtherError . A3BackendErrorResponse (responseCode a3resp) $
            Client.responseBody a3resp
    extractUserPath a3resp
  where
    responseCode = Status.statusCode . Client.responseStatus

-- | Send a password reset request to A3 and return the response.
resetPasswordInA3'P :: Path -> A3Action RequestResult
resetPasswordInA3'P path = do
    config <- AC.getConfig'P
    let a3req = fromMaybe (error "resetPasswordInA3'P: mkRequestForA3 failed, check config!") $
                mkRequestForA3 config "/password_reset" reqData
    a3resp <- liftLIO . ioTCB . sendRequest $ a3req
    either (throwError . OtherError . A3BackendInvalidJson) return $
        (Aeson.eitherDecode . Client.responseBody $ a3resp :: Either String RequestResult)
  where
    reqData = PasswordResetRequest path "dummypass"


-- * policy

a3corsPolicy :: CorsPolicy
a3corsPolicy = CorsPolicy
    { corsHeaders = "Origin, Content-Type, Accept, X-User-Path, X-User-Token"
    , corsMethods = "POST,GET,DELETE,PUT,OPTIONS"
    , corsOrigin  =  "*"
    }


-- * low-level helpers

-- | Convert a persona into a user creation request to be sent to the A3 backend.
-- The name of the persona is used as user name. The email address is set to a unique dummy
-- value and the password is set to a dummy value.
mkUserCreationRequestForA3 :: ThentosConfig -> Persona -> Maybe Client.Request
mkUserCreationRequestForA3 config persona = do
    let user  = UserFormData { udName     = UserName . fromPersonaName $ persona ^. personaName,
                               udEmail    = email,
                               udPassword = "dummypass" }
    mkRequestForA3 config "/principals/users" $ A3UserWithPass user
  where
    email = fromMaybe (error "mkUserCreationRequestForA3: couldn't create dummy email")
                      (parseUserEmail $ cshow (persona ^. personaId) <> "@example.org")

-- | Make a POST request to be sent to the A3 backend. Returns 'Nothing' if the 'ThentosConfig'
-- lacks a correctly configured proxy.
--
-- Note that the request is configured to NOT thrown an exception even if the response status code
-- indicates an error (400 or higher). Properly dealing with error replies is left to the caller.
--
-- Since the A3 frontend doesn't know about different services (i.e. never sends a
-- @X-Thentos-Service@ header), we send the request to the default proxy which should be the A3
-- backend.
mkRequestForA3 :: ToJSON a => ThentosConfig -> String -> a -> Maybe Client.Request
mkRequestForA3 config route dat = do
    defaultProxy <- Tagged <$> config >>. (Proxy :: Proxy '["proxy"])
    let target = extractTargetUrl defaultProxy
    initReq <- Client.parseUrl $ cs $ show target <//> route
    return initReq { Client.method = "POST"
        , Client.requestHeaders = [("Content-Type", "application/json")]
        , Client.requestBody = Client.RequestBodyLBS . Aeson.encode $ dat
        , Client.checkStatus = \_ _ _ -> Nothing
        }

-- | Extract the user path from an A3 response received for a user creation request.
extractUserPath :: (MonadError (ThentosError ThentosA3Error) m) => Client.Response LBS -> m Path
extractUserPath resp = do
    resource <- either (throwError . OtherError . A3BackendInvalidJson) return $
        (Aeson.eitherDecode . Client.responseBody $ resp :: Either String TypedPath)
    pure $ tpPath resource

sendRequest :: Client.Request -> IO (Client.Response LBS)
sendRequest req = Client.newManager Client.defaultManagerSettings >>= Client.httpLbs req

-- | A3-specific ProxyAdapter.
a3ProxyAdapter :: ProxyAdapter
a3ProxyAdapter = ProxyAdapter
  { renderHeader = renderA3HeaderName
  , renderUser   = a3RenderUser
  , renderError  = a3BaseActionErrorToServantErr
  }

-- | Render Thentos/A3-specific custom headers using the names expected by A3.
renderA3HeaderName :: RenderHeaderFun
renderA3HeaderName ThentosHeaderSession = mk "X-User-Token"
renderA3HeaderName ThentosHeaderUser    = mk "X-User-Path"
renderA3HeaderName h                    = renderThentosHeaderName h

-- | Render the user as A3 expects it.
a3RenderUser :: ThentosConfig -> UserId -> User -> SBS
a3RenderUser cfg uid _ = cs . fromPath $ userIdToPath cfg uid

userIdToPath :: ThentosConfig -> UserId -> Path
userIdToPath config (UserId i) = a3backendPath config $
    cs (printf "principals/users/%7.7i/" i :: String)

-- | Convert a local file name into a absolute path relative to the A3 backend endpoint.
a3backendPath :: ThentosConfig -> ST -> Path
a3backendPath config localPath = Path $ cs (exposeUrl beHttp) <//> localPath
  where
    beHttp     = case config >>. (Proxy :: Proxy '["backend"]) of
                     Nothing -> error "a3backendPath: backend not configured!"
                     Just v -> Tagged v

userIdFromPath :: MonadError (ThentosError e) m => Path -> m UserId
userIdFromPath (Path s) = do
    uri <- either (const . throwError . MalformedUserPath $ s) return $
        URI.parseURI URI.laxURIParserOptions $ cs s
    rawId <- maybe (throwError $ MalformedUserPath s) return $
        stripPrefix "/principals/users/" $ dropWhileEnd (== '/') (cs $ URI.uriPath uri)
    maybe (throwError NoSuchUser) (return . UserId) $ readMay rawId
