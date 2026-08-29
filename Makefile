COMPOSE = docker compose -f srcs/docker-compose.yml
all: up

up:
	mkdir -p /home/kmitsuki/data/mariadb /home/kmitsuki/data/wordpress
	$(COMPOSE) up -d --build
down:
	$(COMPOSE) down

re: down up
clean:
	$(COMPOSE) down --rmi all --volumes
fclean: clean
	@echo "Data in /home/kmitsuki/data is preserved."

.PHONY: all up down re clean fclean
