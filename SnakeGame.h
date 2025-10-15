#import <MetalKit/MetalKit.h>

#define GRID_WIDTH 30
#define GRID_HEIGHT 20
#define MAX_SNAKE_LENGTH 100

typedef struct {
    int x;
    int y;
} SPoint;

typedef enum {
    DIR_UP,
    DIR_RIGHT,
    DIR_DOWN,
    DIR_LEFT
} Direction;

typedef enum {
    GAME_STATE_START,
    GAME_STATE_PLAYING,
    GAME_STATE_GAME_OVER
} GameState;

@interface SnakeGame : MTKView <MTKViewDelegate>

@property (strong, nonatomic) id<MTLDevice> device;
@property (strong, nonatomic) id<MTLCommandQueue> commandQueue;
@property (strong, nonatomic) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic) SPoint food;
@property (nonatomic) Direction direction;
@property (nonatomic) Direction nextDirection;
@property (nonatomic) int snakeLength;
@property (nonatomic) BOOL gameOver;
@property (nonatomic) GameState gameState;
@property (nonatomic) int score;
@property (strong, nonatomic) NSTimer *gameTimer;
@property (strong, nonatomic) NSTimer *displayTimer; // Added for smooth animation

- (void)initGame;
- (void)spawnFood;

@end

// Snake segment positions
extern SPoint snake[MAX_SNAKE_LENGTH];
