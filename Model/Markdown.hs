module Model.Markdown where

import Import

import Text.Regex.TDFA
import Text.Regex.TDFA.ByteString
import Yesod.Markdown (markdownToHtml, Markdown (..))

import qualified Prelude as Partial (init)

import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BS

import Data.Text.Encoding

fixLinks :: Text -> Text -> Text
fixLinks project' line' =
    let Right pattern = compile defaultCompOpt defaultExecOpt "(\\[[^]]*\\])\\(([a-z]+:)?([a-z0-9-]+)\\)"
        project = encodeUtf8 project'
        parse _   (Left err) = error err
        parse str (Right Nothing) = str
        parse _   (Right (Just (pre, _, post, [link, proj, page]))) = mconcat
            [ pre
            , link
            , "("
                , "/p/" <> if BS.null proj then project else BS.init proj
                , "/w/" <> page
            , ")"
            ] <> parse post (regexec pattern post)

        parse _ (Right (Just _)) = error "strange match"

        line = encodeUtf8 line'
     in decodeUtf8 $ parse line (regexec pattern line)


linkTickets :: Text -> Handler Text
linkTickets line' = do
    let Right pattern = compile defaultCompOpt defaultExecOpt "\\<SD-([0-9][0-9]*)" -- TODO word boundaries?
        getLinkForTicketComment :: TicketId -> Handler (Maybe Text)
        getLinkForTicketComment ticket_id = do
            info <- runDB $ select $ from $ \ (ticket `InnerJoin` comment `LeftOuterJoin` page `LeftOuterJoin` project) -> do
                on_ $ project ?. ProjectId ==. page ?. WikiPageProject
                on_ $ page ?. WikiPageDiscussion ==. just (comment ^. CommentDiscussion)
                on_ $ ticket ^. TicketComment ==. comment ^. CommentId
                where_ $ ticket ^. TicketId ==. val ticket_id

                return
                    ( comment ^. CommentId
                    , project ?. ProjectHandle
                    , page ?. WikiPageTarget
                    )

            case map unwrapValues info of
                [] -> return Nothing
                (Key (PersistInt64 comment_id), Just handle, Just target) : _ -> return $ Just $ mconcat
                    [ "/p/", handle, "/w/", target, "/c/",  T.pack (show comment_id) ]

                _ -> error "Unexpected result for ticket reference"

        parse _   (Left err) = error err
        parse str (Right Nothing) = return str
        parse _   (Right (Just (pre, _, post, [ticket_number]))) = do
            $(logError) $ T.pack $ show $  T.unpack $ decodeUtf8 ticket_number
            maybe_link <- getLinkForTicketComment $ Key $ PersistInt64 $ read $ T.unpack $ decodeUtf8 ticket_number
            rest <- parse post (regexec pattern post)
            return $ mconcat
                [ pre
                , "[SD-" <> ticket_number <> "]"
                , case maybe_link of
                    Nothing -> ""
                    Just link -> mconcat [ "(", encodeUtf8 link, ")" ]
                ] <> rest

        parse _ (Right (Just _)) = error "strange match"

        line = encodeUtf8 line'
     in fmap decodeUtf8 $ parse line (regexec pattern line)


renderMarkdown :: Text -> Markdown -> Handler Html
renderMarkdown project (Markdown markdown) = do
    let ls = T.lines markdown

    ls' <- mapM (linkTickets . fixLinks project) ls

    return $ markdownToHtml $ Markdown $ T.unlines ls'


markdownWidget :: Text -> Markdown -> Widget
markdownWidget project markdown = do
    rendered <- handlerToWidget $ renderMarkdown project markdown
    toWidget rendered

