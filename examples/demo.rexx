/* demo.rexx -- example end-user program using RXPIP packages */
/* REQUIRE mathutils */
/* REQUIRE greetutils */

say Shout('world')
say 'square of 7 is' Square(7)
say 'cube of 3 is' Cube(3)
if IsPrime(17) then say '17 is prime'
else say '17 is not prime'
