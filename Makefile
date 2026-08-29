COMPOSE = docker compose -f srcs/docker-compose.yml
all: up

up:
	mkdir -p /home/$(USER)/data/mariadb /home/$(USER)/data/wordpress
	$(COMPOSE) up -d --build
down:
	$(COMPOSE) down

re: down up
clean:
	$(COMPOSE) down --rmi all --volumes
fclean: clean
	@echo "Data in /home/$(USER)/data is preserved."

.PHONY: all up down re clean fclean
