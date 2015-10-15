{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Servant.Missing where

import Servant
import Servant.Server.Internal
import Servant.HTML.Blaze

import Control.Monad.IO.Class
import Text.Digestive
import Network.Wai (Request, Response, responseLBS)
import Network.HTTP.Types (ok200)
import Data.Text (Text)
import Text.Blaze.Html5 as H
import Text.Blaze.Renderer.Utf8
import Network.Wai.Digestive

-- Combinators for digestive-functors
--
-- The 'FormGet' combinator returns the HTML for the form, and takes a unit
-- handler. The 'FormPost f v a' combinator provides an argument for the handler
-- of type 'a' in case the form can be validated; otherwise it automatically
-- returns the HTML corresponding to the error.
--
-- > type API = "form" :> FormGet "PersonForm" Html Person
-- >       :<|> "form" :> FormPost "PersonForm" Html Person :> Post '[HTML] Person
-- >
-- > server :: Server API
-- > server = () :<|> id
-- >
-- > data Person = Person { name :: String, age :: Int }
-- >
-- > personForm :: Monad m => Form Html m Person
-- > personForm = Person <$> "name" .: nonEmptyText
-- >                     <*> "age"  .: positiveInt
-- >   where
-- >     nonEmptyText = check "Cannot be empty" (not . Data.Text.null)
-- >                  $ text Nothing
-- >     positiveInt  = check "Must be postive" (>= 0) $ stringRead Nothing
-- >
-- > renderPersonForm :: View Html -> Html
-- > renderPersonForm v = ...
-- >
-- > instance HasForm "PersonForm" Html Person where
-- >    isForm _   = personForm
-- >    formView _ = renderPersonForm

data FormPost f v a
data FormGet f v a

backend = undefined

toServantErr :: ToMarkup v => v -> ServantErr
toServantErr v = err400 { errBody = renderHtml $ toHtml v }

render :: Html -> RouteResult Response
render x = Route $ responseLBS ok200 [] $ renderHtml x

class HasForm f v a | f -> v, f -> a where
    isForm :: Proxy f -> Form v m a
    formView :: Proxy f -> View v -> v

instance (HasForm f v a, ToMarkup v, HasServer sublayout)
         => HasServer (FormPost f v a :> sublayout) where
    type ServerT (FormPost f v a :> sub) m = a -> ServerT sub m
    route _ subserver = WithRequest $ \req ->
      route (Proxy :: Proxy sublayout) (addBodyCheck subserver $ go req)
      where
        fp = Proxy :: Proxy f
        go req = do
           (v, a) <- runFormP req "test" $ isForm fp
           case a of
             Nothing -> return $ Fail (toServantErr $ formView fp v)
             Just a' -> return $ Route a'

instance (HasForm f v a, ToMarkup v) => HasServer (FormGet f v a) where
    type ServerT (FormGet f v a) m = m ()
    route _ _ = LeafRouter route'
      where
        fp = Proxy :: Proxy f
        route' req respond = do
          v <- runFormG "test" $ isForm fp
          respond . render . toHtml $ formView fp v


runFormG :: Monad m => Text -> Form v m a -> m (View v)
runFormG = getForm

runFormP :: MonadIO m => Request -> Text -> Form v m a -> m (View v, Maybe a)
runFormP req name form = postForm name form $ \x -> case x of
    MultiPart -> bodyFormEnv backend req
