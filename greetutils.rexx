/* greetutils.rexx -- part of the "greetutils" RXPIP package
   Depends on: strutils >= 1.0.0
   Exposes:  Shout(name)
*/

Shout: procedure
  parse arg name
  return 'HELLO, ' || StrReverse(StrReverse(translate(name))) || '!!!'
