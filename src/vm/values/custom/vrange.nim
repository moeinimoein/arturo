#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2022 Yanis Zafirópulos
#
# @file: vm/values/custom/vrange.nim
#=======================================================

## The internal `:range` type

#=======================================
# Libraries
#=======================================

#=======================================
# Types
#=======================================

# TODO(VRange) Should we support BigNum bounds?
#  so that somebody can e.g. select.first:3 167126537612537126536127..∞ => prime?
# labels: enhancement, values, open discussion

type
    GenericRange[T] = ref object
        start*      : T
        stop*       : T
        step*       : T
        infinite*   : bool
        numeric*    : bool 
        forward*    : bool

    VRange* = GenericRange[int]

#=======================================
# Constants
#=======================================

const
    InfiniteRange* = high(int) - 1

#=======================================
# Methods
#=======================================

func len*(self: VRange): int =
    if self.infinite:
        return InfiniteRange
    else:
        return (abs(self.stop - self.start) div abs(self.step)) + 1

func reversed*(self: VRange): VRange =
    VRange(
        start: self.stop,
        stop: self.start,
        step: self.step,
        infinite: self.infinite,
        numeric: self.numeric,
        forward: not self.forward
    )

#=======================================
# Overloads
#=======================================

func `==`*(a, b: VRange): bool {.inline,enforceNoRaises.} =
    a[] == b[]

func `$`*(v: VRange): string {.inline,enforceNoRaises.} =
    var start: string
    var stop: string

    if v.numeric: start = $(v.start)
    else: start = "`" & $(chr(v.start)) & "`"

    if v.infinite: stop = "∞"
    else: 
        if v.numeric: stop = $(v.stop)
        else: stop = "`" & $(chr(v.stop)) & "`"

    result = start & ".." & stop

    if v.step != 1:
        result &= " (" & $(v.step) & ")"