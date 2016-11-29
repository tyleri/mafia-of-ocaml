default:
	@echo "Usage:"
	@echo "  make test                      runs tests"
	@echo "  make client URL=[server URL]   runs client and connects to server"
	@echo "  make server                    runs server"
	@echo "  make game                      runs game"
	@echo "  make test_game				    runs test_game

daemon:
	corebuild -pkgs async,cohttp.async daemon.byte && ./daemon.byte

server:
	corebuild -pkgs cohttp.async,yojson game_server.byte && ./game_server.byte

test:
	corebuild -pkgs yojson,ansiterminal,ounit test.byte && ./test.byte

client:
	corebuild -pkgs yojson,str,async,lwt,cohttp,cohttp.async,ANSITerminal client.byte && ./client.byte ${URL}

game:
	corebuild -pkgs yojson game.byte && ./game.byte

test_game:
	corebuild -pkgs yojson,ansiterminal,ounit test_game.byte && ./test_game.byte


