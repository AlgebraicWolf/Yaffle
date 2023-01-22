module Idris.Syntax.TTC

import public Core.Binary
import public Core.TTC

import TTImp.TTImp
import TTImp.TTImp.TTC

import Idris.Syntax

import Libraries.Data.ANameMap
import Libraries.Data.NameMap
import Libraries.Data.SortedMap
import Libraries.Data.StringMap

%default covering

export
TTC Method where
  toBuf (MkMethod nm c treq ty)
      = do toBuf nm
           toBuf c
           toBuf treq
           toBuf ty

  fromBuf
      = do nm <- fromBuf
           c <- fromBuf
           treq <- fromBuf
           ty <- fromBuf
           pure (MkMethod nm c treq ty)

export
TTC IFaceInfo where
  toBuf (MkIFaceInfo ic impps ps cs ms ds)
      = do toBuf ic
           toBuf impps
           toBuf ps
           toBuf cs
           toBuf ms
           toBuf ds

  fromBuf
      = do ic <- fromBuf
           impps <- fromBuf
           ps <- fromBuf
           cs <- fromBuf
           ms <- fromBuf
           ds <- fromBuf
           pure (MkIFaceInfo ic impps ps cs ms ds)

export
TTC Fixity where
  toBuf InfixL = tag 0
  toBuf InfixR = tag 1
  toBuf Infix = tag 2
  toBuf Prefix = tag 3

  fromBuf
      = case !getTag of
             0 => pure InfixL
             1 => pure InfixR
             2 => pure Infix
             3 => pure Prefix
             _ => corrupt "Fixity"

export
TTC Import where
  toBuf (MkImport loc reexport path nameAs)
    = do toBuf loc
         toBuf reexport
         toBuf path
         toBuf nameAs

  fromBuf
    = do loc <- fromBuf
         reexport <- fromBuf
         path <- fromBuf
         nameAs <- fromBuf
         pure (MkImport loc reexport path nameAs)

export
TTC SyntaxInfo where
  toBuf syn
      = do toBuf (StringMap.toList (infixes syn))
           toBuf (StringMap.toList (prefixes syn))
           toBuf (filter (\n => elemBy (==) (fst n) (saveMod syn))
                           (SortedMap.toList $ modDocstrings syn))
           toBuf (filter (\n => elemBy (==) (fst n) (saveMod syn))
                           (SortedMap.toList $ modDocexports syn))
           toBuf (filter (\n => fst n `elem` saveIFaces syn)
                           (ANameMap.toList (ifaces syn)))
           toBuf (filter (\n => isJust (lookup (fst n) (saveDocstrings syn)))
                           (ANameMap.toList (defDocstrings syn)))
           toBuf (bracketholes syn)
           toBuf (startExpr syn)
           toBuf (holeNames syn)

  fromBuf
      = do inf <- fromBuf
           pre <- fromBuf
           moddstr <- fromBuf
           modexpts <- fromBuf
           ifs <- fromBuf
           defdstrs <- fromBuf
           bhs <- fromBuf
           start <- fromBuf
           hnames <- fromBuf
           pure $ MkSyntax (fromList inf) (fromList pre)
                   [] (fromList moddstr) (fromList modexpts)
                   [] (fromList ifs)
                   empty (fromList defdstrs)
                   bhs
                   [] start
                   hnames
