CC = gcc
CFLAGS = -O3 -march=native -Wall -pthread

find_jhash_collision: find_jhash_collision.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f find_jhash_collision

.PHONY: clean
