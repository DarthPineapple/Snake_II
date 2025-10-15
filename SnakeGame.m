#import "SnakeGame.h"
#import <simd/simd.h>
#import <stddef.h>         // added for offsetof

typedef struct {
    vector_float2 position;
    vector_float4 color;
} Vertex;

// Structure for visual positions with floating point values
typedef struct {
    float x;
    float y;
} SPointF;

// Define the snake array
SPoint snake[MAX_SNAKE_LENGTH];

@implementation SnakeGame {
    SPointF visualPositions[MAX_SNAKE_LENGTH];
    SPoint prevSnake[MAX_SNAKE_LENGTH]; // Store previous logical positions for interpolation
    float interpolationFactor;
    CFTimeInterval lastFrameTime;
    CFTimeInterval lastGameUpdateTime;
    const double snakeMoveInterval; // 0.1s for 10 moves/sec
}

@dynamic device;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupMetal];
        [self initGame];
        
        // Configure the Metal view for proper rendering
        self.preferredFramesPerSecond = 60;
        self.enableSetNeedsDisplay = NO; // Use continuous rendering
        self.paused = NO; // Ensure rendering is not paused
        
        // Create a single timer for both game logic and display updates at 60 FPS
        self.gameTimer = [NSTimer timerWithTimeInterval:1.0/60.0
                                                 target:self
                                               selector:@selector(updateGameAndDisplay)
                                               userInfo:nil
                                                repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.gameTimer forMode:NSRunLoopCommonModes];
        lastFrameTime = CACurrentMediaTime();
        lastGameUpdateTime = lastFrameTime;
        interpolationFactor = 0.0f;
        *(double *)&snakeMoveInterval = 0.1; // 0.1s for 10 moves/sec
        [self performSelector:@selector(requestFirstResponderStatus) withObject:nil afterDelay:0.5];
    }
    return self;
}

- (void)setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    
    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm; // Ensure pixel format matches the pipeline descriptor
    self.clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
    
    NSString *shaderSource = @
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct Vertex {\n"
        "    float2 position [[attribute(0)]];\n"
        "    float4 color [[attribute(1)]];\n"
        "};\n"
        "struct RasterizerData {\n"
        "    float4 position [[position]];\n"
        "    float4 color;\n"
        "};\n"
        "vertex RasterizerData vertexShader(Vertex in [[stage_in]]) {\n"
        "    RasterizerData out;\n"
        "    out.position = float4(in.position, 0.0, 1.0);\n"
        "    out.color = in.color;\n"
        "    return out;\n"
        "}\n"
        "fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {\n"
        "    return in.color;\n"
        "}\n";
    
    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource options:nil error:&error];
    
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat; // Match pixel format
    
    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
    vertexDescriptor.attributes[1].offset = offsetof(Vertex, color);
    vertexDescriptor.attributes[1].bufferIndex = 0;
    
    vertexDescriptor.layouts[0].stride = sizeof(Vertex);
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    
    pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
}

- (void)initGame {
    self.snakeLength = 3;
    self.direction = DIR_RIGHT;
    self.nextDirection = DIR_RIGHT;
    self.gameOver = NO;
    self.gameState = GAME_STATE_START;
    self.score = 0;
    NSLog(@"Game Initialized - Press SPACE to start");
    for (int i = 0; i < self.snakeLength; i++) {
        snake[i] = (SPoint){GRID_WIDTH / 2 - i, GRID_HEIGHT / 2};
        prevSnake[i] = snake[i];
        visualPositions[i] = (SPointF){(float)snake[i].x, (float)snake[i].y};
    }
    [self spawnFood];
    lastFrameTime = CACurrentMediaTime();
    lastGameUpdateTime = lastFrameTime;
    interpolationFactor = 0.0f;
    *(double *)&snakeMoveInterval = 0.1; // 0.1s for 10 moves/sec
}

- (void)spawnFood {
    SPoint food;
    do {
        food.x = arc4random_uniform(GRID_WIDTH);
        food.y = arc4random_uniform(GRID_HEIGHT);
    } while ([self isFoodOnSnakeWithPoint:food]);
    self.food = food;
}

- (BOOL)isFoodOnSnakeWithPoint:(SPoint)point {
    for (int i = 0; i < self.snakeLength; i++) {
        if (snake[i].x == point.x && snake[i].y == point.y) {
            return YES;
        }
    }
    return NO;
}

- (void)updateGame {
    if (self.gameOver || self.gameState != GAME_STATE_PLAYING) return;

    self.direction = self.nextDirection;

    SPoint newHead = snake[0];
    switch (self.direction) {
        case DIR_UP: newHead.y--; break;
        case DIR_DOWN: newHead.y++; break;
        case DIR_LEFT: newHead.x--; break;
        case DIR_RIGHT: newHead.x++; break;
    }

    if (newHead.x < 0 || newHead.x >= GRID_WIDTH ||
        newHead.y < 0 || newHead.y >= GRID_HEIGHT) {
        self.gameOver = YES;
        self.gameState = GAME_STATE_GAME_OVER;
        return;
    }

    BOOL ateFood = (newHead.x == self.food.x && newHead.y == self.food.y);

    // Check for collision with the body before moving
    for (int i = 1; i < self.snakeLength; i++) {
        if (snake[i].x == newHead.x && snake[i].y == newHead.y) {
            self.gameOver = YES;
            self.gameState = GAME_STATE_GAME_OVER;
            return;
        }
    }

    // Move the snake body 
    if (ateFood) {
        // When eating food, we need to ensure we have space for the new segment
        if (self.snakeLength < MAX_SNAKE_LENGTH - 1) {
            // Insert new segment at the tail's current position
            SPoint tail = snake[self.snakeLength - 1];
            snake[self.snakeLength] = tail;
            prevSnake[self.snakeLength] = tail;
            self.snakeLength++;
            self.score += 10; // Increment score
        }
        // Move body segments but preserve the tail
        for (int i = self.snakeLength - 1; i > 0; i--) {
            snake[i] = snake[i - 1];
        }
    } else {
        // Normal movement (without growing)
        for (int i = self.snakeLength - 1; i > 0; i--) {
            snake[i] = snake[i - 1];
        }
    }

    // Update head position
    snake[0] = newHead;

    if (ateFood) {
        [self spawnFood];
    }
}

// Combined method to update game logic and display at 60 FPS
- (void)updateGameAndDisplay {
    CFTimeInterval currentTime = CACurrentMediaTime();
    CFTimeInterval frameDeltaTime = currentTime - lastFrameTime;
    lastFrameTime = currentTime;
    if (frameDeltaTime > 0.1) frameDeltaTime = 0.1;

    // Calculate interpolation factor for smooth movement
    interpolationFactor = (currentTime - lastGameUpdateTime) / snakeMoveInterval;
    if (interpolationFactor > 1.0f) interpolationFactor = 1.0f;

    // Update game logic at 5 moves per second (every 0.2s)
    if ((currentTime - lastGameUpdateTime) >= snakeMoveInterval) {
        // Store previous snake positions for interpolation
        for (int i = 0; i < self.snakeLength; i++) {
            prevSnake[i] = snake[i];
        }
        [self updateGame];
        lastGameUpdateTime += snakeMoveInterval;
        interpolationFactor = 0.0f;
    }

    // Interpolate visual positions between prevSnake and snake
    for (int i = 0; i < self.snakeLength; i++) {
        float prevX = (float)prevSnake[i].x;
        float prevY = (float)prevSnake[i].y;
        float currX = (float)snake[i].x;
        float currY = (float)snake[i].y;
        visualPositions[i].x = prevX + (currX - prevX) * interpolationFactor;
        visualPositions[i].y = prevY + (currY - prevY) * interpolationFactor;
    }
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    unichar key = chars.length > 0 ? [chars characterAtIndex:0] : 0;
    switch (event.keyCode) {
        case 126: // Up arrow
            if (self.gameState == GAME_STATE_PLAYING && self.direction != DIR_DOWN) self.nextDirection = DIR_UP;
            break;
        case 125: // Down arrow
            if (self.gameState == GAME_STATE_PLAYING && self.direction != DIR_UP) self.nextDirection = DIR_DOWN;
            break;
        case 123: // Left arrow
            if (self.gameState == GAME_STATE_PLAYING && self.direction != DIR_RIGHT) self.nextDirection = DIR_LEFT;
            break;
        case 124: // Right arrow
            if (self.gameState == GAME_STATE_PLAYING && self.direction != DIR_LEFT) self.nextDirection = DIR_RIGHT;
            break;
        case 49: // Space
            if (self.gameState == GAME_STATE_START) {
                self.gameState = GAME_STATE_PLAYING;
                NSLog(@"Game Started!");
            } else if (self.gameOver) {
                [self initGame];
            }
            break;
        default:
            // WASD and Vim keys
            if (self.gameState == GAME_STATE_PLAYING) {
                if ((key == 'w' || key == 'k') && self.direction != DIR_DOWN) {
                    self.nextDirection = DIR_UP;
                } else if ((key == 's' || key == 'j') && self.direction != DIR_UP) {
                    self.nextDirection = DIR_DOWN;
                } else if ((key == 'a' || key == 'h') && self.direction != DIR_RIGHT) {
                    self.nextDirection = DIR_LEFT;
                } else if ((key == 'd' || key == 'l') && self.direction != DIR_LEFT) {
                    self.nextDirection = DIR_RIGHT;
                } else {
                    [super keyDown:event];
                }
            } else {
                [super keyDown:event];
            }
            break;
    }
}

- (void)requestFirstResponderStatus {
    if (self.window) {
        [self.window makeFirstResponder:self];
        
        // Check if we are the first responder
        NSResponder *currentFirstResponder = self.window.firstResponder;
        
        // Print responder chain for debugging
        NSResponder *responder = self;
        int depth = 0;
        while (responder && depth < 10) {
            responder = responder.nextResponder;
            depth++;
        }
    }
}

- (void)drawInMTKView:(MTKView *)view {
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    
    if (renderPassDescriptor != nil) {
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        
        [renderEncoder setRenderPipelineState:self.pipelineState];
        
        // Use NSMutableData for vertex storage to avoid @encode warnings
        NSMutableData *vertexData = [NSMutableData data];
        
        float cellWidth = 2.0 / GRID_WIDTH;
        float cellHeight = 2.0 / GRID_HEIGHT;

        if (self.gameState == GAME_STATE_START) {
            // Draw start screen
            [self drawStartScreen:vertexData];
        } else {
            // Draw snake using interpolated visual positions with curved corners
            [self drawSnakeWithCurvedCorners:vertexData cellWidth:cellWidth cellHeight:cellHeight];

            // Draw food - fix Y coordinate mapping
            float fx = -1.0 + (self.food.x + 0.5f) * cellWidth;
            float fy = 1.0 - (self.food.y + 0.5f) * cellHeight; // Flip y-axis
            [self addQuadToVertexData:vertexData x:fx y:fy width:cellWidth * 0.8 height:cellHeight * 0.8 color:(vector_float4){1.0, 0.0, 0.0, 1.0}];

            // Draw game over screen
            if (self.gameOver) {
                [self drawGameOverScreen:vertexData];
            }
        }
        
        NSUInteger vertexCount = vertexData.length / sizeof(Vertex);
        
        if (vertexCount > 0) {
            id<MTLBuffer> vertexBuffer = [self.device newBufferWithBytes:vertexData.bytes
                                                                 length:vertexData.length
                                                                options:MTLResourceStorageModeShared];
            
            [renderEncoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertexCount];
        }
        
        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }
    
    [commandBuffer commit];
}

// Fix the addQuadToVertexData method to ensure correct triangle winding
- (void)addQuadToVertexData:(NSMutableData *)vertexData x:(float)x y:(float)y width:(float)w height:(float)h color:(vector_float4)color {
    // Center the quad at (x, y)
    float halfW = w * 0.5f;
    float halfH = h * 0.5f;
    
    Vertex v0 = {{x - halfW, y - halfH}, color}; // Bottom left
    Vertex v1 = {{x + halfW, y - halfH}, color}; // Bottom right
    Vertex v2 = {{x - halfW, y + halfH}, color}; // Top left
    Vertex v3 = {{x + halfW, y + halfH}, color}; // Top right
    
    // Create two triangles with correct winding order
    Vertex quad[] = {v0, v2, v1, v2, v3, v1}; // split into two clockwise triangles
    [vertexData appendBytes:quad length:sizeof(quad)];
}

// Helper method to add a circle (for curved corners)
- (void)addCircleToVertexData:(NSMutableData *)vertexData x:(float)x y:(float)y radius:(float)r color:(vector_float4)color segments:(int)segments {
    float angleStep = (M_PI * 2.0f) / segments;
    
    for (int i = 0; i < segments; i++) {
        float angle1 = i * angleStep;
        float angle2 = (i + 1) * angleStep;
        
        Vertex v0 = {{x, y}, color}; // Center
        Vertex v1 = {{x + cos(angle1) * r, y + sin(angle1) * r}, color};
        Vertex v2 = {{x + cos(angle2) * r, y + sin(angle2) * r}, color};
        
        Vertex triangle[] = {v0, v1, v2};
        [vertexData appendBytes:triangle length:sizeof(triangle)];
    }
}

// Helper method to draw snake with curved corners
- (void)drawSnakeWithCurvedCorners:(NSMutableData *)vertexData cellWidth:(float)cellWidth cellHeight:(float)cellHeight {
    float segmentSize = cellWidth * 0.9f;  // Size of snake segments
    
    for (int i = 0; i < self.snakeLength; i++) {
        float x = -1.0 + (visualPositions[i].x + 0.5f) * cellWidth;
        float y = 1.0 - (visualPositions[i].y + 0.5f) * cellHeight;
        vector_float4 color = (i == 0) ? (vector_float4){0.0, 1.0, 0.0, 1.0} : (vector_float4){0.0, 0.8, 0.0, 1.0};
        
        // Determine directions to previous and next segments using logical positions
        int prevDx = 0, prevDy = 0, nextDx = 0, nextDy = 0;
        BOOL hasPrev = NO, hasNext = NO;
        
        if (i > 0) {
            prevDx = snake[i].x - snake[i-1].x;
            prevDy = snake[i].y - snake[i-1].y;
            hasPrev = YES;
        }
        
        if (i < self.snakeLength - 1) {
            nextDx = snake[i+1].x - snake[i].x;
            nextDy = snake[i+1].y - snake[i].y;
            hasNext = YES;
        }
        
        // Check if this is a corner (perpendicular direction change)
        BOOL isCorner = NO;
        if (hasPrev && hasNext) {
            isCorner = ((prevDx != 0 && nextDy != 0) || (prevDy != 0 && nextDx != 0));
        }
        
        if (isCorner) {
            // Draw corner with smooth rounded edges
            // Approach: Draw an L-shaped body with a rounded outer corner
            
            float halfSize = segmentSize * 0.5f;
            float radius = segmentSize * 0.5f;
            
            // Draw center square
            [self addQuadToVertexData:vertexData x:x y:y width:segmentSize height:segmentSize color:color];
            
            // Convert grid directions to screen offsets (remember Y is flipped)
            float prevScreenX = prevDx * cellWidth;
            float prevScreenY = -prevDy * cellHeight;
            float nextScreenX = nextDx * cellWidth;
            float nextScreenY = -nextDy * cellHeight;
            
            // Draw arm extending toward previous segment
            if (prevDx != 0) {
                // Horizontal arm
                float armX = x + prevScreenX * 0.5f;
                [self addQuadToVertexData:vertexData x:armX y:y width:halfSize height:segmentSize color:color];
            } else {
                // Vertical arm
                float armY = y + prevScreenY * 0.5f;
                [self addQuadToVertexData:vertexData x:x y:armY width:segmentSize height:halfSize color:color];
            }
            
            // Draw arm extending toward next segment
            if (nextDx != 0) {
                // Horizontal arm
                float armX = x + nextScreenX * 0.5f;
                [self addQuadToVertexData:vertexData x:armX y:y width:halfSize height:segmentSize color:color];
            } else {
                // Vertical arm
                float armY = y + nextScreenY * 0.5f;
                [self addQuadToVertexData:vertexData x:x y:armY width:segmentSize height:halfSize color:color];
            }
            
            // Now add a rounded quarter-circle on the OUTSIDE of the corner
            // The "outside" is the side away from the inside angle
            
            // Determine the outside corner position
            float outerCornerX = x + (prevScreenX + nextScreenX) * 0.5f;
            float outerCornerY = y + (prevScreenY + nextScreenY) * 0.5f;
            
            // Calculate the angle for the arc
            // We draw from the end of one arm to the end of the other arm
            float angle1 = atan2f(prevScreenY, prevScreenX);
            float angle2 = atan2f(nextScreenY, nextScreenX);
            
            // Ensure we draw the arc in the correct direction (the outside arc)
            float angleDiff = angle2 - angle1;
            
            // Normalize to [-PI, PI]
            while (angleDiff > M_PI) angleDiff -= 2 * M_PI;
            while (angleDiff < -M_PI) angleDiff += 2 * M_PI;
            
            // Draw the quarter circle arc
            int numSegments = 10;
            for (int j = 0; j < numSegments; j++) {
                float t1 = (float)j / numSegments;
                float t2 = (float)(j + 1) / numSegments;
                float a1 = angle1 + angleDiff * t1;
                float a2 = angle1 + angleDiff * t2;
                
                Vertex v0 = {{outerCornerX, outerCornerY}, color};
                Vertex v1 = {{outerCornerX + cosf(a1) * radius, outerCornerY + sinf(a1) * radius}, color};
                Vertex v2 = {{outerCornerX + cosf(a2) * radius, outerCornerY + sinf(a2) * radius}, color};
                
                Vertex triangle[] = {v0, v1, v2};
                [vertexData appendBytes:triangle length:sizeof(triangle)];
            }
            
        } else {
            // Draw regular straight segment
            [self addQuadToVertexData:vertexData x:x y:y width:cellWidth * 0.9 height:cellHeight * 0.9 color:color];
        }
    }
}

// Draw start screen
- (void)drawStartScreen:(NSMutableData *)vertexData {
    // Background
    [self addQuadToVertexData:vertexData x:0.0f y:0.0f width:2.0f height:2.0f color:(vector_float4){0.0, 0.2, 0.0, 1.0}];
    
    // Title: "SNAKE II"
    vector_float4 titleColor = (vector_float4){0.0, 1.0, 0.0, 1.0};
    float titleSize = 0.12f;
    float titleSpacing = 0.15f;
    float titleStartX = -0.45f;
    float titleY = 0.4f;
    
    [self drawLetterS:vertexData x:titleStartX y:titleY size:titleSize color:titleColor];
    [self drawLetterN:vertexData x:titleStartX + titleSpacing y:titleY size:titleSize color:titleColor];
    [self drawLetterA:vertexData x:titleStartX + titleSpacing * 2 y:titleY size:titleSize color:titleColor];
    [self drawLetterK:vertexData x:titleStartX + titleSpacing * 3 y:titleY size:titleSize color:titleColor];
    [self drawLetterE:vertexData x:titleStartX + titleSpacing * 4 y:titleY size:titleSize color:titleColor];
    
    [self drawLetterI:vertexData x:titleStartX + titleSpacing * 5.5f y:titleY size:titleSize color:titleColor];
    [self drawLetterI:vertexData x:titleStartX + titleSpacing * 6.2f y:titleY size:titleSize color:titleColor];
    
    // Instructions
    vector_float4 instructColor = (vector_float4){0.8, 0.8, 0.8, 1.0};
    float instrSize = 0.05f;
    float instrSpacing = 0.07f;
    
    // "PRESS SPACE"
    float line1Y = 0.0f;
    float line1StartX = -0.35f;
    [self drawLetterP:vertexData x:line1StartX y:line1Y size:instrSize color:instructColor];
    [self drawLetterR:vertexData x:line1StartX + instrSpacing y:line1Y size:instrSize color:instructColor];
    [self drawLetterE:vertexData x:line1StartX + instrSpacing * 2 y:line1Y size:instrSize color:instructColor];
    [self drawLetterS:vertexData x:line1StartX + instrSpacing * 3 y:line1Y size:instrSize color:instructColor];
    [self drawLetterS:vertexData x:line1StartX + instrSpacing * 4 y:line1Y size:instrSize color:instructColor];
    
    [self drawLetterS:vertexData x:line1StartX + instrSpacing * 6 y:line1Y size:instrSize color:instructColor];
    [self drawLetterP:vertexData x:line1StartX + instrSpacing * 7 y:line1Y size:instrSize color:instructColor];
    [self drawLetterA:vertexData x:line1StartX + instrSpacing * 8 y:line1Y size:instrSize color:instructColor];
    [self drawLetterC:vertexData x:line1StartX + instrSpacing * 9 y:line1Y size:instrSize color:instructColor];
    [self drawLetterE:vertexData x:line1StartX + instrSpacing * 10 y:line1Y size:instrSize color:instructColor];
    
    // "TO START"
    float line2Y = -0.15f;
    float line2StartX = -0.25f;
    [self drawLetterT:vertexData x:line2StartX y:line2Y size:instrSize color:instructColor];
    [self drawLetterO:vertexData x:line2StartX + instrSpacing y:line2Y size:instrSize color:instructColor];
    
    [self drawLetterS:vertexData x:line2StartX + instrSpacing * 3 y:line2Y size:instrSize color:instructColor];
    [self drawLetterT:vertexData x:line2StartX + instrSpacing * 4 y:line2Y size:instrSize color:instructColor];
    [self drawLetterA:vertexData x:line2StartX + instrSpacing * 5 y:line2Y size:instrSize color:instructColor];
    [self drawLetterR:vertexData x:line2StartX + instrSpacing * 6 y:line2Y size:instrSize color:instructColor];
    [self drawLetterT:vertexData x:line2StartX + instrSpacing * 7 y:line2Y size:instrSize color:instructColor];
    
    // Controls info
    float controlsY = -0.45f;
    float controlsSize = 0.04f;
    float controlsSpacing = 0.06f;
    float controlsStartX = -0.3f;
    
    // "USE ARROW KEYS"
    [self drawLetterU:vertexData x:controlsStartX y:controlsY size:controlsSize color:instructColor];
    [self drawLetterS:vertexData x:controlsStartX + controlsSpacing y:controlsY size:controlsSize color:instructColor];
    [self drawLetterE:vertexData x:controlsStartX + controlsSpacing * 2 y:controlsY size:controlsSize color:instructColor];
    
    [self drawLetterA:vertexData x:controlsStartX + controlsSpacing * 4 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterR:vertexData x:controlsStartX + controlsSpacing * 5 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterR:vertexData x:controlsStartX + controlsSpacing * 6 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterO:vertexData x:controlsStartX + controlsSpacing * 7 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterW:vertexData x:controlsStartX + controlsSpacing * 8 y:controlsY size:controlsSize color:instructColor];
    
    [self drawLetterK:vertexData x:controlsStartX + controlsSpacing * 10 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterE:vertexData x:controlsStartX + controlsSpacing * 11 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterY:vertexData x:controlsStartX + controlsSpacing * 12 y:controlsY size:controlsSize color:instructColor];
    [self drawLetterS:vertexData x:controlsStartX + controlsSpacing * 13 y:controlsY size:controlsSize color:instructColor];
}

// Draw improved game over screen
- (void)drawGameOverScreen:(NSMutableData *)vertexData {
    // Semi-transparent overlay
    [self addQuadToVertexData:vertexData x:0.0f y:0.0f width:2.0f height:2.0f color:(vector_float4){0.0, 0.0, 0.0, 0.8}];
    
    // "GAME OVER" text
    vector_float4 textColor = (vector_float4){1.0, 0.2, 0.2, 1.0}; // Red color
    float blockSize = 0.1f;
    float spacing = 0.12f;
    float startX = -0.5f;
    float startY = 0.3f;
    
    [self drawLetterG:vertexData x:startX y:startY size:blockSize color:textColor];
    [self drawLetterA:vertexData x:startX + spacing y:startY size:blockSize color:textColor];
    [self drawLetterM:vertexData x:startX + spacing * 2 y:startY size:blockSize color:textColor];
    [self drawLetterE:vertexData x:startX + spacing * 3 y:startY size:blockSize color:textColor];
    
    [self drawLetterO:vertexData x:startX + spacing * 5 y:startY size:blockSize color:textColor];
    [self drawLetterV:vertexData x:startX + spacing * 6 y:startY size:blockSize color:textColor];
    [self drawLetterE:vertexData x:startX + spacing * 7 y:startY size:blockSize color:textColor];
    [self drawLetterR:vertexData x:startX + spacing * 8 y:startY size:blockSize color:textColor];
    
    // Score display
    vector_float4 scoreColor = (vector_float4){1.0, 1.0, 0.0, 1.0}; // Yellow
    float scoreSize = 0.06f;
    float scoreSpacing = 0.08f;
    float scoreY = 0.0f;
    float scoreStartX = -0.25f;
    
    // "SCORE:"
    [self drawLetterS:vertexData x:scoreStartX y:scoreY size:scoreSize color:scoreColor];
    [self drawLetterC:vertexData x:scoreStartX + scoreSpacing y:scoreY size:scoreSize color:scoreColor];
    [self drawLetterO:vertexData x:scoreStartX + scoreSpacing * 2 y:scoreY size:scoreSize color:scoreColor];
    [self drawLetterR:vertexData x:scoreStartX + scoreSpacing * 3 y:scoreY size:scoreSize color:scoreColor];
    [self drawLetterE:vertexData x:scoreStartX + scoreSpacing * 4 y:scoreY size:scoreSize color:scoreColor];
    
    // Draw score digits (simple implementation for numbers 0-999)
    float digitX = scoreStartX + scoreSpacing * 5.5f;
    int displayScore = self.score;
    if (displayScore > 999) displayScore = 999;
    
    int hundreds = displayScore / 100;
    int tens = (displayScore / 10) % 10;
    int ones = displayScore % 10;
    
    if (hundreds > 0) {
        [self drawDigit:vertexData digit:hundreds x:digitX y:scoreY size:scoreSize color:scoreColor];
        digitX += scoreSpacing * 0.8f;
    }
    if (hundreds > 0 || tens > 0) {
        [self drawDigit:vertexData digit:tens x:digitX y:scoreY size:scoreSize color:scoreColor];
        digitX += scoreSpacing * 0.8f;
    }
    [self drawDigit:vertexData digit:ones x:digitX y:scoreY size:scoreSize color:scoreColor];
    
    // "Press SPACE to restart" message
    vector_float4 msgColor = (vector_float4){1.0, 1.0, 1.0, 1.0};
    float msgY = -0.25f;
    float msgBlockSize = 0.05f;
    float msgSpacing = 0.07f;
    float msgStartX = -0.35f;
    
    [self drawLetterP:vertexData x:msgStartX y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterR:vertexData x:msgStartX + msgSpacing y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterE:vertexData x:msgStartX + msgSpacing * 2 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterS:vertexData x:msgStartX + msgSpacing * 3 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterS:vertexData x:msgStartX + msgSpacing * 4 y:msgY size:msgBlockSize color:msgColor];
    
    [self drawLetterS:vertexData x:msgStartX + msgSpacing * 6 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterP:vertexData x:msgStartX + msgSpacing * 7 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterA:vertexData x:msgStartX + msgSpacing * 8 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterC:vertexData x:msgStartX + msgSpacing * 9 y:msgY size:msgBlockSize color:msgColor];
    [self drawLetterE:vertexData x:msgStartX + msgSpacing * 10 y:msgY size:msgBlockSize color:msgColor];
}

// Helper methods to draw simple block letters
- (void)drawLetterG:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.7f width:s*0.2f height:s*0.6f color:c]; // right
    [self addQuadToVertexData:data x:x+s*0.1f y:y-s*0.6f width:s*0.4f height:s*0.2f color:c]; // middle
}

- (void)drawLetterA:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.8f height:s*0.2f color:c]; // middle
}

- (void)drawLetterM:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // right
    [self addQuadToVertexData:data x:x-s*0.15f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // middle left
    [self addQuadToVertexData:data x:x+s*0.15f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // middle right
}

- (void)drawLetterE:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.8f height:s*0.2f color:c]; // middle
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterO:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterV:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.3f width:s*0.2f height:s*0.8f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.3f width:s*0.2f height:s*0.8f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*0.9f width:s*0.4f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterR:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // right top
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.8f height:s*0.2f color:c]; // middle
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // right bottom
}

- (void)drawLetterP:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.8f height:s*0.2f color:c]; // middle
}

- (void)drawLetterS:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // left top
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.8f height:s*0.2f color:c]; // middle
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // right bottom
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterC:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self.window makeFirstResponder:self];
        self.window.initialFirstResponder = self;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeKey:)
                                                     name:NSWindowDidBecomeKeyNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeMain:)
                                                     name:NSWindowDidBecomeMainNotification
                                                   object:self.window];
        [self performSelector:@selector(requestFirstResponderStatus) withObject:nil afterDelay:0.1];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (self.window) {
        [self.window makeFirstResponder:self];
    }
}

- (void)windowDidBecomeMain:(NSNotification *)notification {
    if (self.window) {
        [self.window makeFirstResponder:self];
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return YES;
}

- (BOOL)resignFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

// Add manual keyboard event handling method for testing
- (void)flagsChanged:(NSEvent *)event {
    // No-op
}

// Add mouse methods to help with debugging responder status
- (void)mouseDown:(NSEvent *)event {
    if (self.window) {
        [self.window makeFirstResponder:self];
    }
}

- (void)drawLetterC:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterN:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.15f height:s*1.0f color:c]; // diagonal
}

- (void)drawLetterK:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.2f width:s*0.15f height:s*0.6f color:c]; // top right diagonal
    [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.8f width:s*0.15f height:s*0.6f color:c]; // bottom right diagonal
}

- (void)drawLetterI:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // middle
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterT:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x y:y width:s*0.8f height:s*0.2f color:c]; // top
    [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // vertical
}

- (void)drawLetterU:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.4f width:s*0.2f height:s*0.8f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.4f width:s*0.2f height:s*0.8f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.8f height:s*0.2f color:c]; // bottom
}

- (void)drawLetterW:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // right
    [self addQuadToVertexData:data x:x y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // middle bottom
}

- (void)drawLetterY:(NSMutableData *)data x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    [self addQuadToVertexData:data x:x-s*0.3f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // top left
    [self addQuadToVertexData:data x:x+s*0.3f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // top right
    [self addQuadToVertexData:data x:x y:y-s*0.7f width:s*0.2f height:s*0.8f color:c]; // bottom middle
}

- (void)drawDigit:(NSMutableData *)data digit:(int)digit x:(float)x y:(float)y size:(float)s color:(vector_float4)c {
    switch (digit) {
        case 0:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 1:
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // vertical
            break;
        case 2:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // top right
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // bottom left
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 3:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 4:
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.2f width:s*0.2f height:s*0.6f color:c]; // top left
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // right
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            break;
        case 5:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // top left
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // bottom right
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 6:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.8f width:s*0.2f height:s*0.4f color:c]; // bottom right
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 7:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.2f color:c]; // right
            break;
        case 8:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // left
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
        case 9:
            [self addQuadToVertexData:data x:x y:y width:s*0.6f height:s*0.2f color:c]; // top
            [self addQuadToVertexData:data x:x-s*0.2f y:y-s*0.2f width:s*0.2f height:s*0.4f color:c]; // top left
            [self addQuadToVertexData:data x:x+s*0.2f y:y-s*0.5f width:s*0.2f height:s*1.0f color:c]; // right
            [self addQuadToVertexData:data x:x y:y-s*0.5f width:s*0.6f height:s*0.2f color:c]; // middle
            [self addQuadToVertexData:data x:x y:y-s*1.0f width:s*0.6f height:s*0.2f color:c]; // bottom
            break;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.gameTimer invalidate];
    [super dealloc];
}

@end
