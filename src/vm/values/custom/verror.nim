
import std/strformat

type
    VError* = ref object of CatchableError
        kind*: VErrorKind
        
    VErrorKind* = ref object
        label*: string

proc newDefaultError(): VError =
    const labelID = "Generic Error"
    result = VError(kind: VErrorKind(label: labelID))
    result.msg = labelID
    return result

let 
    genericError*: VError = newDefaultError()

func `$`*(kind: VErrorKind): string {.inline,enforceNoRaises.} =
    kind.label

func `$`*(error: VError): string {.inline,enforceNoRaises.} =
    fmt"{error.kind}: {error.msg}"

