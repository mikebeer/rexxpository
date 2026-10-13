/* mathutils.rexx -- part of the "mathutils" RXPIP package
   Exposes:  Square(n), Cube(n), IsPrime(n)
*/

Square: procedure
  parse arg n
  return n * n

Cube: procedure
  parse arg n
  return n * n * n

IsPrime: procedure
  parse arg n
  if n < 2 then return 0
  if n = 2 then return 1
  if n // 2 = 0 then return 0
  do i = 3 to trunc(sqrt(n)) by 2
    if n // i = 0 then return 0
  end
  return 1

sqrt: procedure
  parse arg x
  if x = 0 then return 0
  g = x / 2
  do 40
    g = (g + x / g) / 2
  end
  return g
