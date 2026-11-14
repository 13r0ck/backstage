||| Datastar server-sent events, rendered per the Datastar SDK spec
||| (https://github.com/starfederation/datastar/blob/main/sdk/ADR.md).
module Datastar.SSE

import Datastar
import Data.List
import Data.List1
import Data.String

%default total

||| How patched elements are applied. Removal is its own event, because it is
||| the only mode that takes no elements.
public export
data PatchMode = Outer | Inner | Replace | Prepend | Append | Before | After

modeName : PatchMode -> String
modeName Outer   = "outer"
modeName Inner   = "inner"
modeName Replace = "replace"
modeName Prepend = "prepend"
modeName Append  = "append"
modeName Before  = "before"
modeName After   = "after"

public export
data Namespace = HtmlNs | SvgNs | MathMlNs

public export
record PatchOptions where
  constructor MkPatchOptions
  ||| `Nothing`: target each top-level element by its id.
  selector          : Maybe String
  mode              : PatchMode
  useViewTransition : Bool
  elementNamespace  : Namespace

export
defaultPatch : PatchOptions
defaultPatch = MkPatchOptions Nothing Outer False HtmlNs

public export
data Event : Type where
  PatchElements  : PatchOptions -> List1 Html -> Event
  RemoveElements : (selector : String) -> Event
  PatchSignals   : (onlyIfMissing : Bool) -> Signals -> Event
  ExecuteScript  : (autoRemove : Bool) -> (script : String) -> Event

||| Morph elements into the page, matched by id.
export
patch : Html -> Event
patch h = PatchElements defaultPatch (singleton h)

||| Set signals in the browser (JSON Merge Patch: `JNull` removes one).
export
setSignals : Signals -> Event
setSignals = PatchSignals False

export
remove : (selector : String) -> Event
remove = RemoveElements

export
runScript : String -> Event
runScript = ExecuteScript True

-- Rendering --------------------------------------------------------------------

dataLines : String -> String -> List String
dataLines key s = map (\l => key ++ " " ++ l) (lines s)

whenTrue : Bool -> String -> List String
whenTrue b s = if b then [s] else []

patchLines : PatchOptions -> List String
patchLines o =
     maybe [] (\s => ["selector " ++ s]) o.selector
  ++ (case o.mode of Outer => []; m => ["mode " ++ modeName m])
  ++ whenTrue o.useViewTransition "useViewTransition true"
  ++ (case o.elementNamespace of
        HtmlNs   => []
        SvgNs    => ["namespace svg"]
        MathMlNs => ["namespace mathml"])

eventLines : Event -> (String, List String)
eventLines (PatchElements o hs) =
  ("datastar-patch-elements", patchLines o ++ concatMap (dataLines "elements" . render) (forget hs))
eventLines (RemoveElements s) =
  ("datastar-patch-elements", ["mode remove", "selector " ++ s])
eventLines (PatchSignals onlyIfMissing ss) =
  ("datastar-patch-signals", whenTrue onlyIfMissing "onlyIfMissing true" ++ ["signals " ++ encode (signalsJson ss)])
eventLines (ExecuteScript autoRemove s) =
  let tag = el "script" (if autoRemove then [attr "data-effect" "el.remove()"] else []) [raw s] in
  ("datastar-patch-elements", ["mode append", "selector body"] ++ dataLines "elements" (render tag))

export
renderEvent : Event -> String
renderEvent e =
  let (ty, ls) = eventLines e in
  "event: " ++ ty ++ "\n" ++ concatMap (\l => "data: " ++ l ++ "\n") ls ++ "\n"

||| An SSE body (`text/event-stream`) containing the events in order.
export
renderEvents : List Event -> String
renderEvents = concatMap renderEvent
