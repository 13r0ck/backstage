||| A small HTML tree. Text and attribute values are always escaped; the only
||| way to emit unescaped markup is the explicit `raw`.
module Datastar.Html

import Data.List
import Data.String

%default total

public export
data Attr = MkAttr String String | Flag String

export
data Html
  = Element String (List Attr) (List Html)
  | VoidElement String (List Attr)
  | Text String
  | Raw String

export
escape : String -> String
escape = concatMap esc . unpack
  where
    esc : Char -> String
    esc '&'  = "&amp;"
    esc '<'  = "&lt;"
    esc '>'  = "&gt;"
    esc '"'  = "&quot;"
    esc '\'' = "&#39;"
    esc c    = singleton c

renderAttr : Attr -> String
renderAttr (MkAttr k v) = " " ++ k ++ "=\"" ++ escape v ++ "\""
renderAttr (Flag k)     = " " ++ k

export
render : Html -> String
render (Element t as cs) =
  "<" ++ t ++ concatMap renderAttr as ++ ">" ++ renderAll cs ++ "</" ++ t ++ ">"
  where
    renderAll : List Html -> String
    renderAll []        = ""
    renderAll (c :: cs) = render c ++ renderAll cs
render (VoidElement t as) = "<" ++ t ++ concatMap renderAttr as ++ ">"
render (Text s) = escape s
render (Raw s)  = s

||| A full page: `<!DOCTYPE html>` followed by `<html>`.
export
document : List Html -> List Html -> String
document hd bd = "<!DOCTYPE html>" ++ render (Element "html" [] [Element "head" [] hd, Element "body" [] bd])

-- Construction ---------------------------------------------------------------

export
text : String -> Html
text = Text

||| Unescaped markup. Only for trusted, static strings.
export
raw : String -> Html
raw = Raw

export
el : String -> List Attr -> List Html -> Html
el = Element

||| An element that has no children or closing tag (`<input>`, `<meta>`, ...).
export
voidEl : String -> List Attr -> Html
voidEl = VoidElement

export div_, p_, span_, h1_, h2_, h3_, section_, main_, header_, footer_, nav_, ul_, ol_, li_, a_, button_, label_, form_, strong_, em_, code_, pre_, title_, style_ : List Attr -> List Html -> Html
div_ = el "div"
p_ = el "p"
span_ = el "span"
h1_ = el "h1"
h2_ = el "h2"
h3_ = el "h3"
section_ = el "section"
main_ = el "main"
header_ = el "header"
footer_ = el "footer"
nav_ = el "nav"
ul_ = el "ul"
ol_ = el "ol"
li_ = el "li"
a_ = el "a"
button_ = el "button"
label_ = el "label"
form_ = el "form"
strong_ = el "strong"
em_ = el "em"
code_ = el "code"
pre_ = el "pre"
title_ = el "title"
style_ = el "style"

export input_, meta_, link_, br_, hr_, img_ : List Attr -> Html
input_ = voidEl "input"
meta_ = voidEl "meta"
link_ = voidEl "link"
br_ = voidEl "br"
hr_ = voidEl "hr"
img_ = voidEl "img"

||| `<script>` with the given attributes and no inline body.
export
scriptSrc : List Attr -> Html
scriptSrc as = Element "script" as []

export
attr : String -> String -> Attr
attr = MkAttr

export id_, class_, href_, src_, type_, value_, name_, placeholder_, for_, charset_, content_, rel_ : String -> Attr
id_ = attr "id"
class_ = attr "class"
href_ = attr "href"
src_ = attr "src"
type_ = attr "type"
value_ = attr "value"
name_ = attr "name"
placeholder_ = attr "placeholder"
for_ = attr "for"
charset_ = attr "charset"
content_ = attr "content"
rel_ = attr "rel"

export disabled_, checked_ : Attr
disabled_ = Flag "disabled"
checked_ = Flag "checked"
