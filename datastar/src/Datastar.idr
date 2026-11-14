||| Typed Datastar (https://data-star.dev) attributes, signals and actions.
|||
||| Signals are checked names, expressions are an opaque `Expr`, and every
||| `data-*` attribute takes the type it needs, so a typo'd signal name or a
||| string where an expression belongs fails at compile time.
module Datastar

import public Datastar.Html
import public Datastar.Json
import Data.List
import Data.String

%default total

||| The Datastar v1 client bundle this package's attributes and events target.
export
clientScript : Html
clientScript = scriptSrc
  [ type_ "module"
  , src_ "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.5/bundles/datastar.js"
  ]

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

||| Letters, digits and `_`, not starting with a digit.
public export
validSignalName : String -> Bool
validSignalName s = case unpack s of
  []        => False
  (c :: cs) => not (isDigit c) && all (\x => isAlphaNum x || x == '_') (c :: cs)

export
record Signal where
  constructor MkSignal
  name : String

||| `signal "count"`. Invalid literal names are compile errors.
export
signal : (n : String) -> {auto 0 ok : validSignalName n = True} -> Signal
signal n = MkSignal n

||| For names only known at runtime.
export
parseSignal : String -> Maybe Signal
parseSignal n = if validSignalName n then Just (MkSignal n) else Nothing

export
signalName : Signal -> String
signalName = name

export
Eq Signal where
  a == b = a.name == b.name

||| Signal values sent to (or received from) the browser.
public export
Signals : Type
Signals = List (Signal, Json)

export
signalsJson : Signals -> Json
signalsJson ss = JObject (map (\(s, v) => (s.name, v)) ss)

||| The top-level fields of a JSON object, keeping only valid signal names.
export
fromJson : Json -> Maybe Signals
fromJson (JObject kvs) = Just (mapMaybe (\(k, v) => map (\s => (s, v)) (parseSignal k)) kvs)
fromJson _             = Nothing

export
lookupSignal : Signal -> Signals -> Maybe Json
lookupSignal s ss = lookup s ss

export
getString : Signal -> Signals -> Maybe String
getString s ss = case lookup s ss of
  Just (JString x) => Just x
  _                => Nothing

export
getNumber : Signal -> Signals -> Maybe Double
getNumber s ss = case lookup s ss of
  Just (JNumber x) => Just x
  _                => Nothing

export
getBool : Signal -> Signals -> Maybe Bool
getBool s ss = case lookup s ss of
  Just (JBool x) => Just x
  _              => Nothing

--------------------------------------------------------------------------------
-- Expressions
--------------------------------------------------------------------------------

||| A Datastar expression (JavaScript evaluated by the client).
export
record Expr where
  constructor MkExpr
  source : String

export
exprSource : Expr -> String
exprSource = source

||| Escape hatch for expressions this module doesn't model.
export
js : String -> Expr
js = MkExpr

||| `$name`
export
sig : Signal -> Expr
sig s = MkExpr ("$" ++ s.name)

export
literal : Json -> Expr
literal = MkExpr . encode

export
str : String -> Expr
str = literal . JString

export
num : Double -> Expr
num = literal . JNumber

||| `$s = e`
export
assign : Signal -> Expr -> Expr
assign s e = MkExpr ("$" ++ s.name ++ " = " ++ e.source)

||| `!e`
export
not_ : Expr -> Expr
not_ e = MkExpr ("!(" ++ e.source ++ ")")

||| Runs expressions in order.
export
seq : List Expr -> Expr
seq es = MkExpr (joinBy "; " (map source es))

public export
data HttpMethod = GET | POST | PUT | PATCH | DELETE

methodName : HttpMethod -> String
methodName GET    = "get"
methodName POST   = "post"
methodName PUT    = "put"
methodName PATCH  = "patch"
methodName DELETE = "delete"

||| A backend action, e.g. `action POST "/increment"` is `@post("/increment")`.
||| The response is expected to be an SSE stream of `Datastar.SSE` events.
export
action : HttpMethod -> (url : String) -> Expr
action m url = MkExpr ("@" ++ methodName m ++ "(" ++ quote url ++ ")")

--------------------------------------------------------------------------------
-- Attributes
--------------------------------------------------------------------------------

public export
data DomEvent = Click | Input | Change | Submit | KeyDown | KeyUp | Focus | Blur | CustomEvent String

eventName : DomEvent -> String
eventName Click           = "click"
eventName Input           = "input"
eventName Change          = "change"
eventName Submit          = "submit"
eventName KeyDown         = "keydown"
eventName KeyUp           = "keyup"
eventName Focus           = "focus"
eventName Blur            = "blur"
eventName (CustomEvent e) = e

||| `data-signals='{...}'`: initial signal values.
export
dataSignals : Signals -> Attr
dataSignals ss = attr "data-signals" (encode (signalsJson ss))

||| `data-bind="s"`: two-way binding between an input and a signal.
export
dataBind : Signal -> Attr
dataBind s = attr "data-bind" s.name

||| `data-text="e"`: sets the element's text to the expression's value.
export
dataText : Expr -> Attr
dataText e = attr "data-text" e.source

||| `data-show="e"`
export
dataShow : Expr -> Attr
dataShow e = attr "data-show" e.source

||| `data-on:event="e"`
export
dataOn : DomEvent -> Expr -> Attr
dataOn ev e = attr ("data-on:" ++ eventName ev) e.source

||| `data-init="e"`: runs when the element is loaded into the DOM.
export
dataInit : Expr -> Attr
dataInit e = attr "data-init" e.source

||| `data-indicator="s"`: `s` is true while a request from this element is in flight.
export
dataIndicator : Signal -> Attr
dataIndicator s = attr "data-indicator" s.name

||| `data-attr:name="e"`
export
dataAttr : String -> Expr -> Attr
dataAttr n e = attr ("data-attr:" ++ n) e.source
