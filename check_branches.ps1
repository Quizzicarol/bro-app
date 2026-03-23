Set-Location C:\Users\produ\Documents\GitHub\bro_app
git fetch bro-app 2>$null
$ahead = git rev-list --count bro-app/main..master
$behind = git rev-list --count master..bro-app/main
$mb = git merge-base master bro-app/main
$mh = git log --oneline bro-app/main -1
"AHEAD=$ahead"
"BEHIND=$behind"
"MB=$mb"
"MAIN_HEAD=$mh"
