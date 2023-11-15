#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2023 Yanis Zafirópulos
#
# @file: helpers/packager.nim
#=======================================================

#=======================================
# Libraries
#=======================================

import algorithm, options, re
import sequtils, strformat, strutils, tables

when not defined(WEB):
    import asyncdispatch, httpClient, os

import extras/miniz

when not defined(WEB):
    import helpers/io
    import helpers/terminal
    import helpers/url

import vm/[env, errors, exec, parse, values/types]

import vm/values/custom/[vsymbol, vversion]

#=======================================
# Types
#=======================================

type
    VersionSpec*        = tuple[min: bool, ver: VVersion]
    VersionLocation*    = tuple[loc: string, ver: VVersion]

#=======================================
# Constants
#=======================================

let
    NoPackageVersion*   = VVersion(major: 0, minor: 0, patch: 0, extra: "")

const
    # Paths
    TmpFolder           = "{HomeDir}.arturo/tmp"
    PackageFolder       = "{HomeDir}.arturo/packages/"
    PackageTmpZip       = TmpFolder & "/pkg.zip"

    SpecLatestUrl       = "https://{pkg}.pkgr.art/spec"
    SpecVersionUrl      = "https://{pkg}.pkgr.art/{version}/spec"

    SpecFolder          = PackageFolder & "specs/"
    SpecPackage         = SpecFolder & "{pkg}/"
    SpecFile            = SpecPackage & "{version}.art"

    CacheFolder         = PackageFolder & "cache/"
    CachePackage        = CacheFolder & "{pkg}/"
    CacheFiles          = CachePackage & "{version}/"

    RepoFolder          = PackageFolder & "repos/"
    RepoPackage         = RepoFolder & "{repo}@{owner}/"
    RepoPackageUrl      = "{pkg}/archive/{branch}.zip"

    # Warnings
    MalformedDepends    = "Malformed .depends field"

#=======================================
# Global Variables
#=======================================

var
    VerbosePackager* = true

#=======================================
# Forward declarations
#=======================================

proc processLocalPackage(pkg: string, verspec: VersionSpec, latest: bool = false): Option[string]
proc processRemotePackage(pkg: string, verspec: VersionSpec): Option[string]
proc verifyDependencies*(deps: seq[Value])

#=====================================
# Template
#=====================================

template ShowMessage(msg: string): untyped =
    if VerbosePackager:
        stdout.write "- " & msg

template ShowWarning(msg: string): untyped =
    if VerbosePackager:
        stdout.write bold(redColor) & "! " & resetColor() & "\n"
        stdout.flushFile()

template ShowMessageNl(msg: string, trail="..."): untyped =
    if VerbosePackager:
        ShowMessage msg & trail
        stdout.write "\n"

template ShowSuccess(): untyped =
    if VerbosePackager:
        stdout.write bold(greenColor) & " ✔" & resetColor() & "\n"
        stdout.flushFile()

template WillShowError(): untyped = 
    if VerbosePackager:
        stdout.flushFile()
        echo ""

#=======================================
# Helpers
#=======================================

proc hasDependencies(item: ValueDict): Option[ValueArray] {.inline.} =
    ## Check if there is a .depends field in the spec
    ## and return its content if it's properly set

    if (item.hasKey("depends") and item["depends"].kind == Block):
        return some(item["depends"].a)

proc hasEntry(item: ValueDict): Option[string] {.inline.} =
    ## Check if there is an .entry field in the spec
    ## and return it if it's properly set

    if (item.hasKey("entry") and item["entry"].kind in {String,Literal}):
        return some(item["entry"].s)

proc hasVersion(item: ValueDict): Option[VVersion] {.inline.} =
    ## Check if there is an .version field in the spec
    ## and return it if it's properly set

    if (item.hasKey("version") and item["version"].kind == Version):
        return some(item["version"].version)

proc hasUrl(item: ValueDict): Option[string] {.inline.} =
    ## Check if there is an .url field in the spec
    ## and return it if it's properly set

    if (item.hasKey("url") and item["url"].kind == String):
        return some(item["url"].s)

proc readSpec(content: string): ValueDict =
    ## Read spec from existing content;
    ## mostly for remote packages where we actually
    ## download the spec directly

    result = execDictionary(doParse(content, isFile=false))

proc readSpec(pkg: string, version: VVersion): ValueDict =
    ## Read spec from locally installed package
    
    let specFile = SpecFile.fmt
    result = execDictionary(doParse(specFile, isFile=true))

proc getEntryPointFromSourceFolder*(folder: string): Option[string] =
    ## In a supposed package source folder,
    ## look either for the 'entry' as defined in the package's info.art
    ## or a main.art file - our default entry point

    var entryPoint = "{folder}/main.art".fmt
    var allOk = true

    if (let infoPath = "{folder}/info.art".fmt; infoPath.fileExists()):
        let infoArt = execDictionary(doParse(infoPath, isFile=true))

        if (let entryName = infoArt.hasEntry(); entryName.isSome):
            entryPoint = "{folder}/{entryName.get()}.art".fmt

        if (let deps = infoArt.hasDependencies(); deps.isSome):
            verifyDependencies(deps.get())

    if not entryPoint.fileExists():
        # should throw?
        allOk = false

    if allOk:
        return some(entryPoint)

proc lookupLocalPackageVersion*(pkg: string, version: VersionSpec): Option[VersionLocation] =
    ## Look for a specific package by name and a version specification
    ## among the ones that are already installed locally

    let packagesPath = CachePackage.fmt

    if packagesPath.dirExists():
        # Get all local versions
        let localVersions = (toSeq(walkDir(packagesPath))).map(
                proc (vers: tuple[kind: PathComponent, path: string]): VersionLocation = 
                    let filepath = vers.path
                    let (_, name, ext) = splitFile(filepath)
                    (filepath, newVVersion(name & ext))
            ).sorted(proc (a: VersionLocation, b: VersionLocation): int = cmp(a.ver, b.ver), order=SortOrder.Descending)

        # Go through them and return the one - if any -
        # that matches the version specification we are looking for
        for found in localVersions:
            if version.min:
                if (found.ver > version.ver or found.ver == version.ver):
                    return some(found)
            else:
                if found.ver == version.ver:
                    return some(found)

proc downloadPackageSourceInto*(url: string, target: string) =
    ## Download url containing a package source, unzip it
    ## and move everything into the target folder
    
    ShowMessage "Downloading sources"

    removeDir(target) # delete it, just in case
    newHttpClient().downloadFile(url, PackageTmpZip.fmt)
    let files = miniz.unzipAndGetFiles(PackageTmpZip.fmt, TmpFolder.fmt)
    let (actualSubFolder, _, _) = splitFile(files[0])
    let actualFolder = TmpFolder.fmt & "/" & actualSubFolder
    createDir(target) # make sure the path (and all subdirs) exist
    moveDir(actualFolder, target)
    discard tryRemoveFile(PackageTmpZip.fmt)

    ShowSuccess()

proc verifyDependencies*(deps: seq[Value]) = 
    ## Verify that all declared dependencies for given package
    ## are met and - if not - install them

    ShowMessageNl "Verifying dependencies"
    
    var depList: seq[(string, VersionSpec)] = @[]
    var depsOk = true
    for dep in deps:
        if dep.kind == Word or dep.kind == Literal or dep.kind == String:
            depList.add((dep.s, (false, NoPackageVersion)))
        elif dep.kind == Block:
            if dep.a[0].kind == Word or dep.a[0].kind == Literal or dep.a[0].kind == String:
                if dep.a.len == 1:
                    depList.add((dep.a[0].s, (false, NoPackageVersion)))
                elif dep.a.len == 2 and dep.a[1].kind == Version:
                    depList.add((dep.a[0].s, (false, dep.a[1].version)))
                elif dep.a.len == 3 and dep.a[1].kind == Symbol and dep.a[2].kind == Version:
                    if dep.a[1].m == greaterequal or dep.a[1].m == greaterthan:
                        depList.add((dep.a[0].s, (true, dep.a[2].version)))
                    elif dep.a[1].m == equal:
                        depList.add((dep.a[0].s, (false, dep.a[2].version)))
                    else:
                        depsOk = false
                else:
                    depsOk = false
            else:
                depsOk = false
        else:
            depsOk = false

    if not depsOk:
        ShowWarning MalformedDepends

    for dep in depList:
        let src = dep[0]
        let version = dep[1]
        if processLocalPackage(src, version).isSome:
            discard
        else:
            if processRemotePackage(src,version).isSome:
                discard

#=====================================

proc processLocalFile(filePath: string): Option[string] =
    ## Check if file exists at given path
    ## or alternatively "file.art"

    if filePath.fileExists():
        ShowMessage "Loading from local file"
        ShowSuccess()
        return some(filePath)
    else:
        if (let fileWithExtension = filePath & ".art"; fileWithExtension.fileExists()):
            ShowMessage "Loading from local file"
            ShowSuccess()
            return some(fileWithExtension)

proc processLocalFolder(folderPath: string): Option[string] =
    ## Check if valid package folder exists 
    ## at given path and return entry filepath

    if folderPath.dirExists():
        if (result = getEntryPointFromSourceFolder(folderPath); result.isSome):
            ShowMessage "Loading from local folder"
            ShowSuccess()

proc processRemoteRepo(pkg: string, branch: string = "main", latest: bool = false): Option[string] =
    ## Check remote github repo with an Arturo
    ## package in it and clone it locally
    
    if pkg.isUrl():

        ShowMessage "Loading from repository"

        var matches: array[2, string]
        if not pkg.match(re"https://github.com/([\w\-]+)/([\w\-]+)", matches):
            WillShowError()
            RuntimeError_PackageRepoNotCorrect(pkg)

        ShowSuccess()

        let owner = matches[0]
        let repo = matches[1]

        let repoFolder = RepoPackage.fmt

        if (not dirExists(repoFolder)) or latest:
            let pkgUrl = RepoPackageUrl.fmt
            try:
                pkgUrl.downloadPackageSourceInto(repoFolder)
            except Exception as e:
                WillShowError()
                if e.msg.contains("404"):
                    RuntimeError_PackageRepoNotFound(pkg)
                else:
                    RuntimeError_PackageUnknownError(pkg)

        return getEntryPointFromSourceFolder(repoFolder)

proc processLocalPackage(pkg: string, verspec: VersionSpec, latest: bool = false): Option[string] =
    ## Check for local package installed in our home folder
    ## and return its entry point

    if latest:
        return processRemotePackage(pkg, verspec)

    if (let localPackage = lookupLocalPackageVersion(pkg, verspec); localPackage.isSome):
        let (packageLocation, version) = localPackage.get()
        ShowMessage "Loading local package: {pkg} {version}".fmt
        
        let packageSpec = readSpec(pkg, version)

        ShowSuccess()

        if (let entryName = hasEntry(packageSpec); entryName.isSome):
            if (let entryFile = packageLocation & "/" & entryName.get(); entryFile.fileExists()):
                return some(entryFile)

proc processRemotePackage(pkg: string, verspec: VersionSpec): Option[string] =
    ## Check if there is a remote package with the given name/specificiation
    ## in our registry

    ShowMessageNl "Querying registry"
    var packageSpecUrl: string 
    if verspec.min:
        packageSpecUrl = SpecLatestUrl.fmt
    else:
        let version = verspec.ver
        packageSpecUrl = SpecVersionUrl.fmt

    var specContent: string
    try:
        specContent = waitFor (newAsyncHttpClient().getContent(packageSpecUrl))
    except Exception:
        RuntimeError_PackageNotFound(pkg)

    ShowMessage "Downloading spec: {pkg}.pkgr.art".fmt

    let spec = readSpec(specContent)
    var version: VVersion
    if (let vv = spec.hasVersion(); vv.isSome):
        version = vv.get()
    else:
        RuntimeError_CorruptRemoteSpec(pkg)

    let specFolder = SpecPackage.fmt
    createDir(specFolder)
    let specFile = "{specFolder}/{version}.art".fmt
    writeToFile(specFile, specContent)
    ShowSuccess()
    
    var pkgUrl: string
    if (let uu = spec.hasUrl(); uu.isSome):
        pkgUrl = uu.get()
    else:
        RuntimeError_CorruptRemoteSpec(pkg)
    
    pkgUrl.downloadPackageSourceInto(CacheFiles.fmt)

    if (let deps = spec.hasDependencies(); deps.isSome):
        verifyDependencies(deps.get())

    ShowMessage "Installing package: {pkg} {version}".fmt
    try:
        discard waitFor (newAsyncHttpClient().getContent("https://pkgr.art/download.php?pkg={pkg}&ver={version}&mgk=18966".fmt))
    except Exception:
        # if this fails, the worst thing that could happen
        # is the package stats won't be updated; so, no big deal
        discard 

    ShowSuccess()

    return processLocalPackage(pkg, verspec)

#=======================================
# Methods
#=======================================

proc getEntryForPackage*(
    pkg: string, 
    verspec: VersionSpec, 
    branch: string = "main",
    latest: bool = false,
    checkForFiles: bool = true
): Option[string] {.inline.} =
    ## Given a package name and a version specification
    ## try to find the best match and return
    ## the appropriate entry source filepath

    if checkForFiles:
        # is it a file?
        if (result = processLocalFile(pkg); result.isSome):
            return

        # maybe it's a folder with a "package" in it?
        if (result = processLocalFolder(pkg); result.isSome):
            return
    
    # maybe it's a github repository url?
    if (result = processRemoteRepo(pkg, branch, latest); result.isSome):
        return

    # maybe it's a package we already have locally?
    if (result = processLocalPackage(pkg, verspec, latest); result.isSome):
        return
    
    # maybe it's a remote package we should fetch?
    if (result = processRemotePackage(pkg, verspec); result.isSome):
        return
