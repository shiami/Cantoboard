//
//  Utils.h
//  Cantoboard
//
//  Created by Alex Man on 3/22/21.
//

#ifndef Utils_h
#define Utils_h

@interface LevelDbTable: NSObject
- (id)init:(NSString*) dbPath createDbIfMissing:(bool) createDbIfMissing;
- (NSString*)get:(NSString*) word;
- (bool)put:(NSString*) key value:(NSString*) value;
- (bool)delete:(NSString*) key;
+ (bool)createEnglishDictionary:(NSArray*) textFilePaths dictDbPath:(NSString*) dbPath;
@end

#endif /* Utils_h */
