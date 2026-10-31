; The jails whose local syslog central logging manages, and what each
; forwards: nothing (local_only) or a reviewed sender its app ships in
; apps/<app>/logging/<source>/.
((receiver logs)
 (jails ((hello local_only)
         (counter counter_service))))
