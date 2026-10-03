/* echoargs.rexx -- verify rxpip run forwards args correctly */
do i = 1 to arg()
  say 'arg' i '= [' || arg(i) || ']'
end
