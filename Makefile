COMPOSE = docker compose -f srcs/docker-compose.yml
all: up

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

re: down up
clean:
	$(COMPOSE) down --rmi all --volumes
fclean: clean
	sudo rm -rf /home/$(USER)/data/mariadb/*
	sudo rm -rf /home/$(USER)/data/wordpress/*

.PHONY: all up down re clean fclean
