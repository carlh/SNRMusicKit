//
//  SMKiTunesContentSource.m
//  SNRMusicKit
//
//  Created by Indragie Karunaratne on 2012-08-21.
//  Copyright (c) 2012 Indragie Karunaratne. All rights reserved.
//

#import "SMKiTunesContentSource.h"
#import "SMKiTunesConstants.h"

#import "NSBundle+SMKAdditions.h"
#import "NSURL+SMKAdditions.h"
#import "NSError+SMKAdditions.h"
#import "NSManagedObjectContext+SMKAdditions.h"
#import "SMKiTunesSyncOperation.h"

@interface SMKiTunesContentSource ()
// Notifications
- (void)_applicationWillTerminate:(NSNotification *)notification;
@end

@implementation SMKiTunesContentSource {
    NSOperationQueue *_operationQueue;
    dispatch_semaphore_t _waiter;
    dispatch_queue_t _backgroundQueue;
}
@synthesize mainQueueObjectContext = _mainQueueObjectContext;
@synthesize backgroundQueueObjectContext = _backgroundQueueObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

- (id)init
{
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:[NSApplication sharedApplication]];
        _operationQueue = [NSOperationQueue new];
        _backgroundQueue = dispatch_queue_create("com.indragie.SNRMusicKit.SNRiTunesContentSource", DISPATCH_QUEUE_SERIAL);
        [self sync];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_waiter)
        dispatch_release(_waiter);
    if (_backgroundQueue)
        dispatch_release(_backgroundQueue);
}

#pragma mark - SMKContentSource

- (NSString *)name { return @"iTunes"; }

+ (BOOL)supportsBatching { return YES; }

- (NSArray *)playlistsWithSortDescriptors:(NSArray *)sortDescriptors
                                batchSize:(NSUInteger)batchSize
                               fetchLimit:(NSUInteger)fetchLimit
                                predicate:(NSPredicate *)predicate
                                withError:(NSError **)error
{
    // If the operation is already running, then create a semaphore to force it to wait till it finishes
    if ([_operationQueue operationCount] != 0 && !_waiter) {
        _waiter = dispatch_semaphore_create(0);
        dispatch_semaphore_wait(_waiter, DISPATCH_TIME_FOREVER);
    }
    // Release the semaphore after we're done with it
    if (_waiter) {
        dispatch_release(_waiter);
        _waiter = NULL;
    }
    // Fetch the objects and return
    return [self.mainQueueObjectContext SMK_fetchWithEntityName:SMKiTunesEntityNamePlaylist
                                              sortDescriptors:sortDescriptors
                                                    predicate:predicate
                                                    batchSize:batchSize
                                                   fetchLimit:fetchLimit error:error];
}

- (void)fetchPlaylistsWithSortDescriptors:(NSArray *)sortDescriptors
                                batchSize:(NSUInteger)batchSize
                               fetchLimit:(NSUInteger)fetchLimit
                                predicate:(NSPredicate *)predicate
                        completionHandler:(void(^)(NSArray *playlists, NSError *error))handler
{
    __block SMKiTunesContentSource *weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
        SMKiTunesContentSource *strongSelf = weakSelf;
        // Check on the main queue if a sync operation is already running
        // If so, create a semaphore 
        if ([_operationQueue operationCount] != 0 && !_waiter) {
            _waiter = dispatch_semaphore_create(0);
            dispatch_semaphore_wait(_waiter, DISPATCH_TIME_FOREVER);
        }
        // Release the semaphore after we're done with it
        if (_waiter) {
            dispatch_release(_waiter);
            _waiter = NULL;
        }
        // Once that's done, tell the MOC on the main queue to run an asynchronous fetch
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.mainQueueObjectContext SMK_asyncFetchWithEntityName:SMKiTunesEntityNamePlaylist sortDescriptors:sortDescriptors predicate:predicate batchSize:batchSize fetchLimit:fetchLimit completionHandler:handler];
        });
    });
}

- (void)deleteStore
{
    _mainQueueObjectContext = nil;
    _backgroundQueueObjectContext = nil;
    _persistentStoreCoordinator = nil;
    NSURL *applicationFilesDirectory = [NSURL SMK_applicationSupportFolder];
    NSURL *url = [applicationFilesDirectory URLByAppendingPathComponent:@"SMKiTunesContentSource.storedata"];
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:url error:&error];
    if (error)
        NSLog(@"Error removing Core Data store at URL %@: %@, %@", url, error, [error userInfo]);
}

#pragma mark - Notifications

- (void)_applicationWillTerminate:(NSNotification *)notification
{
    [self.backgroundQueueObjectContext SMK_saveChanges];
    [self.mainQueueObjectContext SMK_saveChanges];
}

#pragma mark - Sync

- (void)sync
{
    // There's a sync already happening
    if ([_operationQueue operationCount] != 0)
        return;
    
    __block SMKiTunesContentSource *weakSelf = self;
    SMKiTunesSyncOperation *operation = [SMKiTunesSyncOperation new];
    [operation setCompletionBlock:^(SMKiTunesSyncOperation *op, NSUInteger count) {
        SMKiTunesContentSource *strongSelf = weakSelf;
        if (strongSelf->_waiter) {
            dispatch_semaphore_signal(strongSelf->_waiter);
        }
    }];
    [operation setContentSource:self];
    [_operationQueue addOperation:operation];
}

#pragma mark - Core Data Boilerplate

- (NSManagedObjectContext *)mainQueueObjectContext
{
    if (_mainQueueObjectContext) {
        return _mainQueueObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (!coordinator) {
        NSError *error = [NSError SMK_errorWithCode:SMKCoreDataErrorFailedToInitializeStore description:[NSString stringWithFormat:@"Failed to initialize the store for class: %@", NSStringFromClass([self class])]];
        NSLog(@"Error: %@, %@", error, [error userInfo]);
        return nil;
    }
    _mainQueueObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [_mainQueueObjectContext setPersistentStoreCoordinator:coordinator];
    [_mainQueueObjectContext setUndoManager:nil];
    [_mainQueueObjectContext setContentSource:self];
    return _mainQueueObjectContext;
}

- (NSManagedObjectContext *)backgroundQueueObjectContext
{
    if (_backgroundQueueObjectContext) {
        return _backgroundQueueObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (!coordinator) {
        NSError *error = [NSError SMK_errorWithCode:SMKCoreDataErrorFailedToInitializeStore description:[NSString stringWithFormat:@"Failed to initialize the store for class: %@", NSStringFromClass([self class])]];
        NSLog(@"Error: %@, %@", error, [error userInfo]);
        return nil;
    }
    _backgroundQueueObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [_backgroundQueueObjectContext setPersistentStoreCoordinator:coordinator];
    [_backgroundQueueObjectContext setUndoManager:nil];
    [_backgroundQueueObjectContext setContentSource:self];
    return _backgroundQueueObjectContext;
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel) {
        return _managedObjectModel;
    }
    NSURL *modelURL = [[NSBundle SMK_frameworkBundle] URLForResource:@"SMKiTunesDataModel" withExtension:@"momd"];
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _managedObjectModel;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator) {
        return _persistentStoreCoordinator;
    }
    
    NSManagedObjectModel *mom = [self managedObjectModel];
    if (!mom) {
        NSLog(@"%@:%@ No model to generate a store from", [self class], NSStringFromSelector(_cmd));
        return nil;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *applicationFilesDirectory = [NSURL SMK_applicationSupportFolder];
    NSError *error = nil;
    
    NSDictionary *properties = [applicationFilesDirectory resourceValuesForKeys:@[NSURLIsDirectoryKey] error:&error];
    
    if (!properties) {
        BOOL ok = NO;
        if ([error code] == NSFileReadNoSuchFileError) {
            ok = [fileManager createDirectoryAtPath:[applicationFilesDirectory path] withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if (!ok) {
            NSLog(@"Error reading attributes of application files directrory: %@, %@", error, [error userInfo]);
            return nil;
        }
    } else {
        if (![properties[NSURLIsDirectoryKey] boolValue]) {
            NSString *failureDescription = [NSString stringWithFormat:@"Expected a folder to store application data, found a file (%@).", [applicationFilesDirectory path]];
            error = [NSError SMK_errorWithCode:SMKCoreDataErrorDataStoreNotAFolder description:failureDescription];
            NSLog(@"Error creating data store: %@, %@", error, [error userInfo]);
            return nil;
        }
    }
    
    NSURL *url = [applicationFilesDirectory URLByAppendingPathComponent:@"SMKiTunesContentSource.storedata"];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:mom];
    if (![coordinator addPersistentStoreWithType:NSXMLStoreType configuration:nil URL:url options:nil error:&error]) {
        NSLog(@"Error adding persistent store: %@, %@", error, [error userInfo]);
        return nil;
    }
    _persistentStoreCoordinator = coordinator;
    
    return _persistentStoreCoordinator;
}
@end
