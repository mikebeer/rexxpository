/* strutils.rexx -- part of the "strutils" RXPIP package
   Exposes:  StrReverse(s), Repeat(s,n)

   NOTE: do not name a package routine the same as a REXX built-in
   function (e.g. "Reverse"). REXX identifier lookup is case-insensitive
   and checks internal/external routine labels BEFORE built-ins, so a
   routine called Reverse: would shadow -- and recursively call -- the
   built-in REVERSE(), causing infinite recursion. Always give exported
   routines names that cannot collide with BIFs.
*/

StrReverse: procedure
  parse arg s
  return reverse(s)

Repeat: procedure
  parse arg s, n
  out = ''
  do n
    out = out || s
  end
  return out
