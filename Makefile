CC = /usr/bin/clang
CFLAGS = -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore
TARGET = SnakeGame
SOURCES = main.m SnakeGame.m

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCES)

clean:
	rm -f $(TARGET)

run: $(TARGET)
	./$(TARGET)
