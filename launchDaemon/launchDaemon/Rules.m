//
//  file: Rules.m
//  project: lulu (launch daemon)
//  description: handles rules & actions such as add/delete
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

#import "consts.h"

#import "Rule.h"
#import "Rules.h"
#import "logging.h"
#import "Baseline.h"
#import "KextComms.h"
#import "utilities.h"

//default systems 'allow' rules
NSString* const DEFAULT_RULES[] =
{
    @"/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
    @"/System/Library/CoreServices/AppleIDAuthAgent",
    @"/System/Library/PrivateFrameworks/AssistantServices.framework/assistantd",
    @"/usr/sbin/automount",
    @"/System/Library/PrivateFrameworks/HelpData.framework/Versions/A/Resources/helpd",
    @"/usr/sbin/mDNSResponder",
    @"/sbin/mount_nfs",
    @"/usr/libexec/mount_url",
    @"/usr/sbin/ntpd",
    @"/usr/sbin/ocspd",
    @"/usr/bin/sntp",
    @"/usr/libexec/trustd"
};

/* GLOBALS */

//kext comms object
extern KextComms* kextComms;

//baseline obj
extern Baseline* baseline;

//'rules changed' semaphore
extern dispatch_semaphore_t rulesChanged;

@implementation Rules

@synthesize rules;

//init method
-(id)init
{
    //init super
    self = [super init];
    if(nil != self)
    {
        //alloc
        rules = [NSMutableDictionary dictionary];
    }
    
    return self;
}

//load rules from disk
-(BOOL)load
{
    //result
    BOOL result = NO;
    
    //rule's file
    NSString* rulesFile = nil;
    
    //serialized rules
    NSDictionary* serializedRules = nil;
    
    //rules obj
    Rule* rule = nil;
    
    //init path to rule's file
    rulesFile = [INSTALL_DIRECTORY stringByAppendingPathComponent:RULES_FILE];
    
    //don't exist?
    // likely first time, so generate default rules
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:rulesFile])
    {
        //generate
        if(YES != [self generateDefaultRules])
        {
            //err msg
            logMsg(LOG_ERR, @"failed to generate default rules");
            
            //bail
            goto bail;
        }
        
        //dbg msg
        logMsg(LOG_DEBUG, @"generated default rules");
    }
    
    //load serialized rules from disk
    serializedRules = [NSMutableDictionary dictionaryWithContentsOfFile:[INSTALL_DIRECTORY stringByAppendingPathComponent:RULES_FILE]];
    if(nil == serializedRules)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load rules from: %@", RULES_FILE]);
        
        //bail
        goto bail;
    }
    
    //create rule objects for each
    for(NSString* key in serializedRules)
    {
        //init
        rule = [[Rule alloc] init:key info:serializedRules[key]];
        if(nil == rule)
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load rule for %@", key]);
            
            //skip
            continue;
        }
        
        //add
        self.rules[rule.path] = rule;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"loaded %lu rules from: %@", (unsigned long)self.rules.count, RULES_FILE]);
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//generate default rules
-(BOOL)generateDefaultRules
{
    //flag
    BOOL generated = NO;
    
    //number of default rules
    NSUInteger defaultRulesCount = 0;
    
    //default binary
    NSString* defaultBinary = nil;
    
    //binary
    Binary* binary = nil;
    
    //cs flag
    SecCSFlags csFlags = kSecCSDefaultFlags;
    
    //calculate number of rules
    defaultRulesCount = sizeof(DEFAULT_RULES)/sizeof(DEFAULT_RULES[0]);
    
    //dbg msg
    logMsg(LOG_DEBUG, @"generating default rules");
    
    //iterate overall default rule paths
    // generate binary obj/signing info
    for(NSUInteger i=0; i<defaultRulesCount; i++)
    {
        //extract binary
        defaultBinary = DEFAULT_RULES[i];
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"processing default binary, %@", defaultBinary]);
        
        //skip if binary doesn't exist
        // some don't on newer versions of macOS
        if(YES != [[NSFileManager defaultManager] fileExistsAtPath:defaultBinary])
        {
            //skip
            continue;
        }
        
        //init binary
        binary = [[Binary alloc] init:DEFAULT_RULES[i]];
        if(nil == binary)
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to generate binary for default rule: %@", DEFAULT_RULES[i]]);
            
            //skip
            continue;
        }
        
        //determine appropriate flags
        // 'tis ok if the path bundle is nil
        csFlags = determineCSFlags(binary.path, [NSBundle bundleWithPath:binary.path]);
        
        //generate signing info
        [binary generateSigningInfo:csFlags];
        
        //add
        if(YES != [self add:binary.path signingInfo:binary.signingInfo action:RULE_STATE_ALLOW type:RULE_TYPE_DEFAULT user:0])
        {
            //err msg
            logMsg(LOG_ERR, @"failed to add rule rules");
            
            //skip
            continue;
        }
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"generated %lu default rules", defaultRulesCount]);
    
    //happy
    generated = YES;
    
bail:
    
    return generated;
}

//save to disk
-(BOOL)save
{
    //result
    BOOL result = NO;
    
    //serialized rules
    NSDictionary* serializedRules = nil;

    //serialize
    serializedRules = [self serialize];
    
    //write out
    if(YES != [serializedRules writeToFile:[INSTALL_DIRECTORY stringByAppendingPathComponent:RULES_FILE] atomically:YES])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to save rules to: %@", RULES_FILE]);
        
        //bail
        goto bail;
    }
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//convert list of rule objects to dictionary
-(NSMutableDictionary*)serialize
{
    //serialized rules
    NSMutableDictionary* serializedRules = nil;
    
    //alloc
    serializedRules = [NSMutableDictionary dictionary];
    
    //sync to access
    @synchronized(self.rules)
    {
        //iterate over all
        // serialize & add each rule
        for(NSString* path in self.rules)
        {
            //covert/add
            serializedRules[path] = [rules[path] serialize];
        }
    }
    
    return serializedRules;
}

//find rule
// look up by path, then verify that signing info/hash (still) matches
-(Rule*)find:(Process*)process
{
    //matching rule
    Rule* matchingRule = nil;
    
    //thread priority
    double threadPriority = 0.0f;
    
    //code signing flags
    SecCSFlags codeSigningFlags = kSecCSDefaultFlags;
    
    //hash
    NSString* hash = nil;
    
    //sync to access
    @synchronized(self.rules)
    {
        //extract rule
        // key: path of process
        matchingRule = [self.rules objectForKey:process.path];
        if(nil == matchingRule)
        {
            //not found, bail
            goto bail;
        }
    }

    //found a matching rule, based on path
    // first, if needed, generate signing info for process
    if(nil == process.binary.signingInfo)
    {
        //save thread priority
        threadPriority = [NSThread threadPriority];
        
        //reduce CPU
        [NSThread setThreadPriority:0.25];
        
        //determine appropriate code signing flags
        codeSigningFlags = determineCSFlags(process.binary.path, process.binary.bundle);
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"generating code signing info for %@ (%d) with flags: %d", process.binary.name, process.pid, codeSigningFlags]);
        
        //generate signing info
        [process.binary generateSigningInfo:codeSigningFlags];
        
        //reset thread priority
        [NSThread setThreadPriority:threadPriority];
        
        //dbg msg
        logMsg(LOG_DEBUG, @"done generating code signing info");
    }
    
    //if there's a hash
    // check this first for match
    if(nil != matchingRule.sha1)
    {
        //generate hash
        hash = hashFile(process.binary.path);
        if(YES != [matchingRule.sha1 isEqualToString:hash])
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"binary is unsigned, but hash comparision failed: %@ vs. %@", matchingRule.sha1, hash]);
            
            //unset
            matchingRule = nil;
        }
        
        //either way, bail
        goto bail;
    }
        
    //binary validly signed w/ auths?
    // make sure it (still) matches rule
    if( (nil != process.binary.signingInfo[KEY_SIGNATURE_STATUS]) &&
        (0 != [process.binary.signingInfo[KEY_SIGNING_AUTHORITIES] count]) )
    {
        //validly signed?
        if(noErr != [process.binary.signingInfo[KEY_SIGNATURE_STATUS] intValue])
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"%@ has a signing error (%@)", process.binary.path, process.binary.signingInfo[KEY_SIGNATURE_STATUS]]);
            
            //unset
            matchingRule = nil;
            
            //bail
            goto bail;
        }
        
        //compare all signing auths
        if(YES != [[NSCountedSet setWithArray:matchingRule.signingInfo[KEY_SIGNING_AUTHORITIES]] isEqualToSet: [NSCountedSet setWithArray:process.binary.signingInfo[KEY_SIGNING_AUTHORITIES]]] )
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"signing authority mismatch between %@/%@", matchingRule.signingInfo[KEY_SIGNING_AUTHORITIES], process.binary.signingInfo[KEY_SIGNING_AUTHORITIES]]);
            
            //unset
            matchingRule = nil;
            
            //bail
            goto bail;
        }
    }
    
bail:
    
    return matchingRule;
}

//add a rule
// will generate a hash of binary, if signing info not found...
-(BOOL)add:(NSString*)path signingInfo:(NSDictionary*)signingInfo action:(NSUInteger)action type:(NSUInteger)type user:(NSUInteger)user
{
    //result
    BOOL added = NO;
    
    //rule info
    NSMutableDictionary* ruleInfo = nil;
    
    //hash
    NSString* hash = nil;
    
    //rule
    Rule* rule = nil;
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"adding rule for %@ (%@): action %lu / type: %lu", path, signingInfo, (unsigned long)action, (unsigned long)type]);
    
    //alloc dictionary
    ruleInfo = [NSMutableDictionary dictionary];
    
    //add signing info
    if(nil != signingInfo)
    {
        //add signing info
        ruleInfo[RULE_SIGNING_INFO] = signingInfo;
    }
    
    //item not signed?
    // generate hash (sha1)
    if( (nil == signingInfo) ||
        (noErr != [signingInfo[KEY_SIGNATURE_STATUS] intValue]) )
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"signing info not found for %@, will hash", path]);
        
        //generate hash
        hash = hashFile(path);
        if(0 == hash.length)
        {
            //err msg
            logMsg(LOG_ERR, @"failed to hash file");
            
            //bail
            goto bail;
        }
        
        //add hash
        ruleInfo[RULE_HASH] = hash;
    }
    
    //add rule action
    ruleInfo[RULE_ACTION] = [NSNumber numberWithUnsignedInteger:action];
    
    //add rule type
    ruleInfo[RULE_TYPE] = [NSNumber numberWithUnsignedInteger:type];
    
    //add rule user
    ruleInfo[RULE_USER] = [NSNumber numberWithUnsignedInteger:user];
    
    //sync to access
    @synchronized(self.rules)
    {
        //init rule
        rule = [[Rule alloc] init:path info:ruleInfo];
        
        //add
        self.rules[path] = rule;
        
        //save to disk
        if(YES != [self save])
        {
            //err msg
            logMsg(LOG_ERR, @"failed to save rules");
            
            //bail
            goto bail;
        }
    }
    
    //for any other process
    // tell kernel to add rule
    [self addToKernel:rule];
    
    //signal all threads that rules changed
    while(0 != dispatch_semaphore_signal(rulesChanged));

    //happy
    added = YES;
    
bail:
    
    return added;
}

//update (toggle) existing rule
-(BOOL)update:(NSString*)path action:(NSUInteger)action user:(NSUInteger)user
{
    //result
    BOOL result = NO;
    
    //rule
    Rule* rule = nil;
    
    //sync to access
    @synchronized(self.rules)
    {
        //find rule
        rule = self.rules[path];
        if(nil == rule)
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"ignoring update request for rule, as it doesn't exists: %@", path]);
            
            //bail
            goto bail;
        }
        
        //update
        rule.action = [NSNumber numberWithUnsignedInteger:action];
        
        //save to disk
        [self save];
    }
    
    //for any other process
    // tell kernel to update (add/overwrite) rule
    [self addToKernel:rule];
    
    //signal all threads that rules changed
    while(0 != dispatch_semaphore_signal(rulesChanged));
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//add to kernel
-(void)addToKernel:(Rule*)rule
{
    //find processes and add
    for(NSNumber* processID in getProcessIDs(rule.path, -1))
    {
        //add rule
        [kextComms addRule:[processID unsignedShortValue] action:rule.action.intValue];
    }
    
    return;
}

//delete rule
-(BOOL)delete:(NSString*)path
{
    //result
    BOOL result = NO;
    
    //sync to access
    @synchronized(self.rules)
    {
        //remove
        [self.rules removeObjectForKey:path];
        
        //save to disk
        if(YES != [self save])
        {
            //err msg
            logMsg(LOG_ERR, @"failed to save rules");
            
            //bail
            goto bail;
        }
    }
    
    //find any running processes that match
    // then for each, tell the kernel to delete any rules it has
    for(NSNumber* processID in getProcessIDs(path, -1))
    {
        //remove rule
        [kextComms removeRule:[processID unsignedShortValue]];
    }
    
    //signal all threads that rules changed
    while(0 != dispatch_semaphore_signal(rulesChanged));

    //happy
    result = YES;
    
bail:
    
    return result;
}

//delete all rules
-(BOOL)deleteAll
{
    //result
    BOOL result = NO;

    //error
    NSError* error = nil;
    
    //sync to access
    @synchronized(self.rules)
    {
        //delete all
        for(NSString* path in self.rules.allKeys)
        {
            //remove
            [self.rules removeObjectForKey:path];
            
            //find any running processes that match
            // then for each, tell the kernel to delete any rules it has
            for(NSNumber* processID in getProcessIDs(path, -1))
            {
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"pid (%@)", processID]);
                
                //remove rule
                [kextComms removeRule:[processID unsignedShortValue]];
            }
        }
        
        //remove old rules file
        if(YES == [[NSFileManager defaultManager] fileExistsAtPath:[INSTALL_DIRECTORY stringByAppendingPathComponent:RULES_FILE]])
        {
            //remove
            if(YES != [[NSFileManager defaultManager] removeItemAtPath:[INSTALL_DIRECTORY stringByAppendingPathComponent:RULES_FILE] error:&error])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to delete existing rules file %@ (error: %@)", RULES_FILE, error]);
                
                //bail
                goto bail;
            }
        }
        
    }//sync
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

@end
