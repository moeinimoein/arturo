######################################################
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2020 Yanis Zafirópulos
#
# @file: library/Core.nim
######################################################

#=======================================
# Libraries
#=======================================

import vm/stack, vm/value

#=======================================
# Methods
#=======================================

template Execute*():untyped =
    require(opExecute)

    #let (outp, errC) = execCmdEx(x.s)
    let res = execCmdEx(x.s)
    
    stack.push(newString(res[0]))

template List*():untyped =
    require(opList)

    if (let aSelect = getAttr("select"); aSelect != VNULL):
        if (getAttr("relative") != VNULL):
            stack.push(newStringArray((toSeq(walkDir(x.s, relative=true)).map((x)=>x[1])).filter((x) => x.contains aSelect.s)))
        else:
            stack.push(newStringArray((toSeq(walkDir(x.s)).map((x)=>x[1])).filter((x) => x.contains aSelect.s)))
    else:
        if (getAttr("relative") != VNULL):
            stack.push(newStringArray(toSeq(walkDir(x.s, relative=true)).map((x)=>x[1])))
        else:
            stack.push(newStringArray(toSeq(walkDir(x.s)).map((x)=>x[1])))

    emptyAttrs()
