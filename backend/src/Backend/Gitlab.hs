{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Backend.Gitlab where

------------------------------------------------------------------------------
import           Control.Lens hiding ((.=))
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Aeson.Lens
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import           Data.String.Conv
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Network.HTTP.Client
import qualified Network.HTTP.Client as HC
import           Network.HTTP.Client.TLS
import           Snap.Core
------------------------------------------------------------------------------
import           Backend.Common
import           Backend.Gitlab.Schema
import           Backend.Schedule
import           Backend.Types.ServerEnv
import           Common.Route
import           Common.Types.RepoBuildInfo
------------------------------------------------------------------------------

gitlabHandler :: ServerEnv -> Snap ()
gitlabHandler env = do
  checkToken $ _serverEnv_secretToken env
  eventHeader <- getHeader "X-Gitlab-Event" <$> getRequest
  body <- readRequestBody 1048576 -- TODO what should this number be?
  case eventHeader of
    Just "Merge Request Hook" -> gitlabMergeRequestHandler env $ eitherDecode body
    Just "Push Hook" -> do
      let mp :: Maybe Push = decode body
      forM_ mp $ \p -> liftIO $ do
        --liftIO $ print p
        let proj = _push_project p
        let fullpath = _project_path_with_namespace proj
            ns = T.dropEnd 1 $ T.dropWhileEnd (/= '/') fullpath
        let rbi = RepoBuildInfo
              (_project_name proj)
              ns
              RepoPush
              (_project_git_ssh_url proj)
              (_project_git_http_url proj)
              (_push_ref p)
              (unGitHash $ _push_checkout_sha p)
              (_commit_message $ head $ _push_commits p)
              (_push_user_name p)
              (_push_user_avatar p)

        scheduleBuild env rbi
        --checkOutstandingMergeRequests env p
    _ -> notFound "gitlab event"

checkToken :: Text -> Snap ()
checkToken secret = do
  let secret' = T.encodeUtf8 secret
  tokenHeaders <- getHeader "X-Gitlab-Token" <$> getRequest
  guard (Just secret' == tokenHeaders)

pushMessage :: Push -> Text
pushMessage p =
  let num = _push_total_commits_count p
      maxCommitMessages = 10
      commits = take maxCommitMessages $ _push_commits p
      commitMessages = concatMap (\c -> ["—", _commit_message c]) commits
      extraCommits = if num > maxCommitMessages
                       then ["...and " <> T.pack (show (num - maxCommitMessages)) <> " more."]
                       else []
      content = [ _push_user_name p
                , " pushed "
                , T.pack (show num)
                , " commit"
                , if num == 1 then "" else "s"
                , " to "
                , _push_ref p
                , " of "
                , _repository_name (_push_repository p)
                ]

      hash =  [ "Hash: "
              , unGitHash $ _push_after p
              ]
  in  T.unlines $ (mconcat <$>
        [ content
        , hash
        , commitMessages
        , extraCommits
        ]) ++ map _commit_url commits

gitlabMergeRequestHandler :: ServerEnv -> Either String MergeRequest -> Snap ()
gitlabMergeRequestHandler _ _ = liftIO $ putStrLn "Got gitlab merge request"
  --case mmr of
  --  Left parseErr -> error $ "MR: Couldn't parse merge request payload: " <> parseErr
  --  Right mr | mergeRequestIsActionable mr -> do
  --    (obsolete, mrid) <- dbTransaction (_ci_db env) $ insertMergeRequest mr
  --    dbTransaction (_ci_db env) $ scheduleMerge mrid
  --    liftIO $ forM_ (NE.nonEmpty obsolete) $ unapproveMergeRequests env
  --  Right mr |  _objectAttributes_state (_mergeRequest_object_attributes mr) `elem` ["merged", "closed"] ->
  --    void $ dbTransaction (_ci_db env) $ insertMergeRequest mr -- Insert this so that we know not to try to build this MR anymore
  --  Right mr -> liftIO $ putStrLn $ unwords
  --    [ "MR: Merge request update not actionable:"
  --    , "IID:"
  --    , show (_objectAttributes_iid $ _mergeRequest_object_attributes mr)
  --    , "State:"
  --    , show (_objectAttributes_state $ _mergeRequest_object_attributes mr)
  --    , "Action:"
  --    , show (_objectAttributes_action $ _mergeRequest_object_attributes mr)
  --    ]

mkProjId :: Text -> Text -> Text
mkProjId ns n = T.replace "/" "%2F" $ ns <> "/" <> n

setupGitlabWebhook :: Text -> Text -> Text -> Text -> Text -> IO (Maybe Integer)
setupGitlabWebhook domain gitlabNamespace gitlabProjectName gitlabSecret zeusAccessToken = do
  let projId = mkProjId gitlabNamespace gitlabProjectName
      o = object
        [ "id" .= projId
        , "url" .= (toS domain <> "/" <> gitlabHookPath)
        , "push_events" .= True
        -- , "push_events_branch_filter" .= ""
        , "merge_requests_events" .= True
        , "token" .= zeusAccessToken
        ]
      apiPath = "projects/" <> projId <> "/hooks"
  resp <- sendToGitlab "POST" apiPath gitlabSecret o
  return (responseBody resp ^? _Value . key "id" . _Integer)

deleteGitlabWebhook :: Text -> Text -> Text -> Int -> IO ()
deleteGitlabWebhook gitlabNamespace gitlabProjectName gitlabSecret hookId = do
  -- TODO Use proper url encoding instead of this janky replace
  let projId = mkProjId gitlabNamespace gitlabProjectName
      apiPath = "projects/" <> projId <> "/hooks/" <> T.pack (show hookId)
  _ <- sendToGitlab "DELETE" apiPath gitlabSecret $ object
    [ "id" .= projId
    , "hook_id" .= hookId
    ]

  return ()


sendToGitlab :: ByteString -> Text -> Text -> Value -> IO (HC.Response LB.ByteString)
sendToGitlab meth apiPath secret o = do
    m <- newTlsManager
    initReq <- parseRequest $ "https://gitlab.com/api/v4/" <> T.unpack apiPath
    let req = initReq
            { HC.method = meth
            , requestBody = RequestBodyLBS $ encode o
            , requestHeaders = [ ("Private-Token", T.encodeUtf8 secret)
                               , ("Content-Type", "application/json")
                               ]
            }
    httpLbs req m

--Response {responseStatus = Status {statusCode = 401, statusMessage = "Unauthorized"},
--          responseVersion = HTTP/1.1,
--          responseHeaders = [
--            ("Server","nginx"),
--            ("Date","Tue, 04 Jun 2019 05:52:02 GMT"),
--            ("Content-Type","application/json"),
--            ("Content-Length","30"),
--            ("Cache-Control","no-cache"),
--            ("Vary","Origin"),
--            ("X-Content-Type-Options","nosniff"),
--            ("X-Frame-Options","SAMEORIGIN"),
--            ("X-Request-Id","tcRqbrWquB7"),
--            ("X-Runtime","0.019759"),
--            ("RateLimit-Limit","600"),
--            ("RateLimit-Observed","1"),
--            ("RateLimit-Remaining","599"),
--            ("RateLimit-Reset","1559627582"),
--            ("RateLimit-ResetTime","Tue, 04 Jun 2019 05:53:02 GMT")],
--          responseBody = "{\"message\":\"401 Unauthorized\"}",
--          responseCookieJar = CJ {expose = []},
--          responseClose' = ResponseClose}
