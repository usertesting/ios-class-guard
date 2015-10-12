#import <Foundation/Foundation.h>
#import "CDSearchPathState.h"
#import "CDFile.h"

@interface SDKSymbolExtractor : NSObject

@property (readonly) CDSearchPathState *searchPathState;
@property (strong) NSString *sdkRoot;
@property (assign) CDArch targetArch;
@property (strong, nonatomic, readwrite) NSMutableSet *symbols;

- (BOOL)loadFile:(CDFile *)file error:(NSError **)error depth:(int)depth;
- (void)collectSymbols;

@end
