#import "SDKSymbolExtractor.h"
#import "CDMachOFile.h"
#import "CDLoadCommand.h"
#import "CDLCDylib.h"

@interface SDKSymbolExtractor ()
@property (strong, nonatomic, readwrite) CDSearchPathState *searchPathState;
@property (strong, nonatomic, readwrite) NSMutableDictionary *machOFilesByName;
@end

@implementation SDKSymbolExtractor

- (instancetype)init {
    if (self = [super init]) {
        _searchPathState = [[CDSearchPathState alloc] init];
        _machOFilesByName = [[NSMutableDictionary alloc] init];
        _symbols = [[NSMutableSet alloc] init];
    }
    return self;
}

- (void)collectSymbols {
    for (CDFile *file in self.machOFilesByName.allValues) {
        if (![file.filename containsString:@"UserTesting"]) {
            [self collectSymbolsFromExecutableAtPath:file.filename];
        }
    }
}

- (void)collectSymbolsFromExecutableAtPath:(NSString *)path {
    NSTask *otool = [[NSTask alloc] init];
    [otool setLaunchPath:@"/usr/bin/otool"];
    [otool setArguments:@[@"-o", path]];
    NSPipe *fromOtoolToSed = [NSPipe pipe];
    [otool setStandardOutput:fromOtoolToSed];
    [otool launch];
    NSFileHandle *sedOutput = [fromOtoolToSed fileHandleForReading];
    NSData *data = [sedOutput readDataToEndOfFile];
    
    if (data.length) {
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSError *error;
        NSRegularExpression *regex = [[NSRegularExpression alloc] initWithPattern:@"\\s*name\\s\\dx\\S*\\s(.*)" options:0 error:&error];
        [regex enumerateMatchesInString:output
                                options:0
                                  range:NSMakeRange(0, [output length])
                             usingBlock:^(NSTextCheckingResult * _Nullable result, NSMatchingFlags flags, BOOL * _Nonnull stop) {
                                 [self.symbols addObjectsFromArray:[[output substringWithRange:[result rangeAtIndex:1]] componentsSeparatedByString:@":"]];
                             }];

    }
}

- (BOOL)loadFile:(CDFile *)file error:(NSError **)error depth:(int)depth {
    CDMachOFile *machOFile = [file machOFileWithArch:_targetArch];
//    if (machOFile == nil) {
//        if (error != NULL) {
//            NSString *failureReason;
//            NSString *targetArchName = CDNameForCPUType(_targetArch.cputype, _targetArch.cpusubtype);
//            if ([file isKindOfClass:[CDFatFile class]] && [(CDFatFile *)file containsArchitecture:_targetArch]) {
//                failureReason = [NSString stringWithFormat:@"Fat file doesn't contain a valid Mach-O file for the specified architecture (%@).  "
//                                 "It probably means that class-dump was run on a static library, which is not supported.", targetArchName];
//            } else {
//                failureReason = [NSString stringWithFormat:@"File doesn't contain the specified architecture (%@).  Available architectures are %@.", targetArchName, file.architectureNameDescription];
//            }
//            NSDictionary *userInfo = @{ NSLocalizedFailureReasonErrorKey : failureReason };
//            *error = [NSError errorWithDomain:CDErrorDomain_ClassDump code:0 userInfo:userInfo];
//        }
//        return NO;
//    }
    
    // Set before processing recursively.  This was getting caught on CoreUI on 10.6
    assert([machOFile filename] != nil);
//    [_machOFiles addObject:machOFile];
    _machOFilesByName[machOFile.filename] = machOFile;
    
//    BOOL shouldProcessRecursively = [self shouldProcessRecursively] && depth < _maxRecursiveDepth;
//    if(!shouldProcessRecursively && [self.forceRecursiveAnalyze containsObject:machOFile.importBaseName]) {
//        shouldProcessRecursively = YES;
//        NSLog(@"Forced recursively processing of %@", machOFile.importBaseName);
//    }
    
//    if (shouldProcessRecursively) {
        @try {
            for (CDLoadCommand *loadCommand in [machOFile loadCommands]) {
                if ([loadCommand isKindOfClass:[CDLCDylib class]]) {
                    CDLCDylib *dylibCommand = (CDLCDylib *)loadCommand;
                    if ([dylibCommand cmd] == LC_LOAD_DYLIB) {
                        [self.searchPathState pushSearchPaths:[machOFile runPaths]];
                        {
                            NSString *loaderPathPrefix = @"@loader_path";
                            
                            NSString *path = [dylibCommand path];
                            if ([path hasPrefix:loaderPathPrefix]) {
                                NSString *loaderPath = [machOFile.filename stringByDeletingLastPathComponent];
                                path = [[path stringByReplacingOccurrencesOfString:loaderPathPrefix withString:loaderPath] stringByStandardizingPath];
                            }
                            [self machOFileWithName:path andDepth:depth+1]; // Loads as a side effect
                        }
                        [self.searchPathState popSearchPaths];
                    }
                }
            }
        }
        @catch (NSException *exception) {
            NSLog(@"Caught exception: %@", exception);
            if (error != NULL) {
//                NSDictionary *userInfo = @{
//                                           NSLocalizedFailureReasonErrorKey : @"Caught exception",
//                                           CDErrorKey_Exception             : exception,
//                                           };
//                *error = [NSError errorWithDomain:CDErrorDomain_ClassDump code:0 userInfo:userInfo];
            }
            return NO;
        }
//    }
        
    return YES;
}

- (CDMachOFile *)machOFileWithName:(NSString *)name andDepth:(int)depth {
    NSString *adjustedName = nil;
    NSString *executablePathPrefix = @"@executable_path";
    NSString *rpathPrefix = @"@rpath";
    
    if ([name hasPrefix:executablePathPrefix]) {
        adjustedName = [name stringByReplacingOccurrencesOfString:executablePathPrefix withString:self.searchPathState.executablePath];
    } else if ([name hasPrefix:rpathPrefix]) {
        for (NSString *searchPath in [self.searchPathState searchPaths]) {
            NSString *str = [name stringByReplacingOccurrencesOfString:rpathPrefix withString:searchPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:str]) {
                adjustedName = str;
                break;
            }
        }
        if (adjustedName == nil) {
            adjustedName = name;
        }
    } else if (self.sdkRoot != nil) {
        adjustedName = [self.sdkRoot stringByAppendingPathComponent:name];
    } else {
        adjustedName = name;
    }
    
    CDMachOFile *machOFile = _machOFilesByName[adjustedName];
    if (machOFile == nil) {
        CDFile *file = [CDFile fileWithContentsOfFile:adjustedName searchPathState:self.searchPathState];
        
        if (file == nil || [self loadFile:file error:NULL depth:depth] == NO)
            NSLog(@"Warning: Failed to load: %@", adjustedName);
        
        machOFile = _machOFilesByName[adjustedName];
        if (machOFile == nil) {
            NSLog(@"Warning: Couldn't load MachOFile with ID: %@, adjustedID: %@", name, adjustedName);
        }
    }
    
    return machOFile;
}

@end
