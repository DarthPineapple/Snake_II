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
    NSLog(@"Game Started");
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
    if (self.gameOver) return;

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
        return;
    }

    BOOL ateFood = (newHead.x == self.food.x && newHead.y == self.food.y);

    // Check for collision with the body before moving
    for (int i = 1; i < self.snakeLength; i++) {
        if (snake[i].x == newHead.x && snake[i].y == newHead.y) {
            self.gameOver = YES;
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
            if (self.direction != DIR_DOWN) self.nextDirection = DIR_UP;
            break;
        case 125: // Down arrow
            if (self.direction != DIR_UP) self.nextDirection = DIR_DOWN;
            break;
        case 123: // Left arrow
            if (self.direction != DIR_RIGHT) self.nextDirection = DIR_LEFT;
            break;
        case 124: // Right arrow
            if (self.direction != DIR_LEFT) self.nextDirection = DIR_RIGHT;
            break;
        case 49: // Space
            if (self.gameOver) [self initGame];
            break;
        default:
            // WASD and Vim keys
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

        // Draw snake using interpolated visual positions
        for (int i = 0; i < self.snakeLength; i++) {
            // Use visual positions (interpolated) instead of grid positions
            float x = -1.0 + (visualPositions[i].x + 0.5f) * cellWidth;
            float y = 1.0 - (visualPositions[i].y + 0.5f) * cellHeight; // Flip y-axis
            vector_float4 color = (i == 0) ? (vector_float4){0.0, 1.0, 0.0, 1.0} : (vector_float4){0.0, 0.8, 0.0, 1.0};

            [self addQuadToVertexData:vertexData x:x y:y width:cellWidth * 0.9 height:cellHeight * 0.9 color:color];
        }

        // Draw food - fix Y coordinate mapping
        float fx = -1.0 + (self.food.x + 0.5f) * cellWidth;
        float fy = 1.0 - (self.food.y + 0.5f) * cellHeight; // Flip y-axis
        [self addQuadToVertexData:vertexData x:fx y:fy width:cellWidth * 0.8 height:cellHeight * 0.8 color:(vector_float4){1.0, 0.0, 0.0, 1.0}];

        // Draw game over screen
        if (self.gameOver) {
            // Semi-transparent overlay
            [self addQuadToVertexData:vertexData x:0.0f y:0.0f width:2.0f height:2.0f color:(vector_float4){0.0, 0.0, 0.0, 0.7}];
            
            // "GAME OVER" text using simple rectangles - position from center (0,0)
            vector_float4 textColor = (vector_float4){1.0, 1.0, 1.0, 1.0};
            float blockSize = 0.08f;
            float spacing = 0.1f;
            float startX = -0.45f; // Adjusted for better centering
            float startY = 0.2f;
            
            // G
            [self drawLetterG:vertexData x:startX y:startY size:blockSize color:textColor];
            // A
            [self drawLetterA:vertexData x:startX + spacing y:startY size:blockSize color:textColor];
            // M
            [self drawLetterM:vertexData x:startX + spacing * 2 y:startY size:blockSize color:textColor];
            // E
            [self drawLetterE:vertexData x:startX + spacing * 3 y:startY size:blockSize color:textColor];
            
            // O
            [self drawLetterO:vertexData x:startX + spacing * 5 y:startY size:blockSize color:textColor];
            // V
            [self drawLetterV:vertexData x:startX + spacing * 6 y:startY size:blockSize color:textColor];
            // E
            [self drawLetterE:vertexData x:startX + spacing * 7 y:startY size:blockSize color:textColor];
            // R
            [self drawLetterR:vertexData x:startX + spacing * 8 y:startY size:blockSize color:textColor];
            
            // "Press SPACE to restart" message
            float msgY = -0.1f;
            float msgBlockSize = 0.04f;
            float msgSpacing = 0.06f; // Adjusted for better spacing
            float msgStartX = -0.3f;  // Adjusted for better centering
            
            [self drawLetterP:vertexData x:msgStartX y:msgY size:msgBlockSize color:textColor];
            [self drawLetterR:vertexData x:msgStartX + msgSpacing y:msgY size:msgBlockSize color:textColor];
            [self drawLetterE:vertexData x:msgStartX + msgSpacing * 2 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterS:vertexData x:msgStartX + msgSpacing * 3 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterS:vertexData x:msgStartX + msgSpacing * 4 y:msgY size:msgBlockSize color:textColor];
            
            [self drawLetterS:vertexData x:msgStartX + msgSpacing * 6 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterP:vertexData x:msgStartX + msgSpacing * 7 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterA:vertexData x:msgStartX + msgSpacing * 8 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterC:vertexData x:msgStartX + msgSpacing * 9 y:msgY size:msgBlockSize color:textColor];
            [self drawLetterE:vertexData x:msgStartX + msgSpacing * 10 y:msgY size:msgBlockSize color:textColor];
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.gameTimer invalidate];
    [super dealloc];
}

@end
