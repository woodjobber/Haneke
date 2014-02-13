//
//  HNKCache.m
//  Haneke
//
//  Created by Hermes on 10/02/14.
//  Copyright (c) 2014 Hermes Pique. All rights reserved.
//

#import "HNKCache.h"

@interface UIImage (hnk_utils)

- (CGSize)hnk_aspectFillSizeForSize:(CGSize)size;
- (CGSize)hnk_aspectFitSizeForSize:(CGSize)size;
- (UIImage *)hnk_imageByScalingToSize:(CGSize)newSize;

@end

@interface NSFileManager (hnk_utils)

- (void)hnk_enumerateContentsOfDirectoryAtPath:(NSString*)path orderedByProperty:(NSString*)property ascending:(BOOL)ascending usingBlock:(void(^)(NSURL *url, NSUInteger idx, BOOL *stop))block;

@end

@interface HNKCacheFormat()

@property (nonatomic, assign) unsigned long long diskSize;
@property (nonatomic, weak) HNKCache *cache;
@property (nonatomic, readonly) NSString *directory;
@property (nonatomic, strong) dispatch_queue_t diskQueue;

@end

@interface HNKCache()

@property (nonatomic, readonly) NSString *rootDirectory;

@end


@implementation HNKCache {
    NSMutableDictionary *_memoryCaches;
    NSMutableDictionary *_formats;
    NSString *_rootDirectory;
}

#pragma mark Initializing the cache

- (id)initWithName:(NSString*)name
{
    self = [super init];
    if (self)
    {
        _memoryCaches = [NSMutableDictionary dictionary];
        _formats = [NSMutableDictionary dictionary];

        NSString *cachesDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        static NSString *cachePathComponent = @"com.hpique.haneke";
        NSString *path = [cachesDirectory stringByAppendingPathComponent:cachePathComponent];
        _rootDirectory = [path stringByAppendingPathComponent:name];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

+ (HNKCache*)sharedCache
{
    static HNKCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HNKCache alloc] initWithName:@"shared"];
    });
    return instance;
}

- (void)registerFormat:(HNKCacheFormat *)format
{
    NSString *formatName = format.name;
    if (_formats[formatName])
    {
        [self clearFormatNamed:formatName];
    }
    _formats[formatName] = format;
    format.cache = self;
    NSString *queueName = [NSString stringWithFormat:@"com.hpique.haneke.disk.%@", formatName];
    format.diskQueue = dispatch_queue_create(queueName.UTF8String, NULL);
    dispatch_async(format.diskQueue, ^{
        [self calculateDiskSizeOfFormat:format];
        [self controlDiskCapacityOfFormat:format];
    });
}

- (NSDictionary*)formats
{
    return _formats.copy;
}

#pragma mark Getting images

- (UIImage*)imageForEntity:(id<HNKCacheEntity>)entity formatName:(NSString *)formatName
{
    HNKCacheFormat *format = _formats[formatName];
    NSAssert(format, @"Unknown format %@", formatName);
    
    NSString *key = entity.cacheKey;
    UIImage *image = [self imageForKey:key format:format];
    if (image)
    {
        dispatch_async(format.diskQueue, ^{
            [self updateAccessDateOfImage:image key:key format:format];
        });
        return image;
    }

    NSString *path = [self pathForKey:key format:format];
    __block NSData *imageData;
    dispatch_sync(format.diskQueue, ^{
        imageData = [NSData dataWithContentsOfFile:path];
    });
    if (imageData)
    {
        image = [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale]; // Do not use imageWithContentsOfFile: as it doesn't consider scale
        if (image)
        {
            dispatch_async(format.diskQueue, ^{
                [self updateAccessDateOfImage:image key:key format:format];
            });
            [self setImage:image forKey:key format:format];
            return image;
        }
    }

    UIImage *originalImage = entity.cacheOriginalImage;
    if (!originalImage)
    {
        NSData *originalData = entity.cacheOriginalData;
        originalImage = [UIImage imageWithData:originalData scale:[UIScreen mainScreen].scale];
    }
    image = [format resizedImageFromImage:originalImage];
    [self setImage:image forKey:key format:format];
    dispatch_async(format.diskQueue, ^{
        [self saveImage:image key:key format:format];
    });
    return image;
}

- (BOOL)retrieveImageForEntity:(id<HNKCacheEntity>)entity formatName:(NSString *)formatName completionBlock:(void(^)(id<HNKCacheEntity> entity, NSString *format, UIImage *image))completionBlock
{
    NSString *key = entity.cacheKey;
    return [self retrieveImageForKey:key formatName:formatName completionBlock:^(NSString *key, NSString *formatName, UIImage *image) {
        if (image)
        {
            completionBlock(entity, formatName, image);
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HNKCacheFormat *format = _formats[formatName];
            __block UIImage *originalImage = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                originalImage = entity.cacheOriginalImage;
            });
            if (!originalImage)
            {
                __block NSData *originalData = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    originalData = entity.cacheOriginalData;
                });
                originalImage = [UIImage imageWithData:originalData scale:[UIScreen mainScreen].scale];
            }
            UIImage *image = [format resizedImageFromImage:originalImage];
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self setImage:image forKey:key format:format];
            });
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(entity, formatName, image);
            });
            dispatch_sync(format.diskQueue, ^{
                [self saveImage:image key:key format:format];
            });
        });
    }];
}

- (BOOL)retrieveImageForKey:(NSString*)key formatName:(NSString *)formatName completionBlock:(void(^)(NSString *key, NSString *formatName, UIImage *image))completionBlock
{
    HNKCacheFormat *format = _formats[formatName];
    NSAssert(format, @"Unknown format %@", formatName);
    
    UIImage *image = [self imageForKey:key format:format];
    if (image)
    {
        completionBlock(key, formatName, image);
        dispatch_async(format.diskQueue, ^{
            [self updateAccessDateOfImage:image key:key format:format];
        });
        return YES;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [self pathForKey:key format:format];
        __block NSData *imageData;
        dispatch_sync(format.diskQueue, ^{
            imageData = [NSData dataWithContentsOfFile:path];
        });
        UIImage *image;
        if (imageData && (image = [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale]))
        {
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(key, formatName, image);
            });
            [self setImage:image forKey:key format:format];
            dispatch_sync(format.diskQueue, ^{
                [self updateAccessDateOfImage:image key:key format:format];
            });
        }
        else
        {
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(key, formatName, nil);
            });
        }
    });
    return NO;
}

#pragma mark Setting images

- (void)setImage:(UIImage*)image forKey:(NSString*)key formatName:(NSString*)formatName
{
    HNKCacheFormat *format = _formats[formatName];
    NSAssert(format, @"Unknown format %@", formatName);
    
    [self setImage:image forKey:key format:format];
    dispatch_sync(format.diskQueue, ^{
        [self saveImage:image key:key format:format];
    });
}

#pragma mark Removing images

- (void)clearFormatNamed:(NSString*)formatName
{
    HNKCacheFormat *format = _formats[formatName];
    NSCache *cache = [_memoryCaches objectForKey:formatName];
    [cache removeAllObjects];
    NSString *directory = format.directory;
    dispatch_async(format.diskQueue, ^{
        NSError *error;
        if ([[NSFileManager defaultManager] removeItemAtPath:directory error:&error])
        {
            format.diskSize = 0;
        }
        else
        {
            BOOL isDirectory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory])
            {
                format.diskSize = 0;
            }
            else
            {
                NSLog(@"Failed to remove directory with error %@", error);
            }
        }
    });
}

- (void)removeImagesOfEntity:(id<HNKCacheEntity>)entity
{
    NSString *cacheKey = entity.cacheKey;
    [_memoryCaches enumerateKeysAndObjectsUsingBlock:^(id key, NSCache *cache, BOOL *stop) {
        [cache removeObjectForKey:cacheKey];
    }];
    NSDictionary *formats = _formats.copy;
    [formats enumerateKeysAndObjectsUsingBlock:^(id key, HNKCacheFormat *format, BOOL *stop) {
        dispatch_async(format.diskQueue, ^{
            NSString *path = [self pathForKey:cacheKey format:format];
            [self removeFileAtPath:path format:format];
        });
    }];
}

#pragma mark Private (utils)

- (NSString*)pathForKey:(NSString*)key format:(HNKCacheFormat*)format
{
    NSString *escapedKey = [key stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *path = [format.directory stringByAppendingPathComponent:escapedKey];
    return path;
}

#pragma mark Private (memory)

- (UIImage*)imageForKey:(NSString*)key format:(HNKCacheFormat*)format
{
    NSCache *cache = _memoryCaches[format.name];
    return [cache objectForKey:key];
}

- (void)setImage:(UIImage*)image forKey:(NSString*)key format:(HNKCacheFormat*)format
{
    NSString *formatName = format.name;
    NSCache *cache = _memoryCaches[formatName];
    if (!cache)
    {
        cache = [[NSCache alloc] init];
        _memoryCaches[formatName] = cache;
    }
    [cache setObject:image forKey:key];
}

#pragma mark Private (disk)

- (void)calculateDiskSizeOfFormat:(HNKCacheFormat*)format
{
    NSString *directory = format.directory;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    format.diskSize = 0;
    NSError *error;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directory error:&error];
    if (!contents)
    {
        NSLog(@"Failed to list directory with error %@", error);
        return;
    }
    for (NSString *pathComponent in contents)
    {
        NSString *path = [directory stringByAppendingPathComponent:pathComponent];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
        if (!attributes) continue;
        
        format.diskSize += attributes.fileSize;
    }
}

- (void)controlDiskCapacityOfFormat:(HNKCacheFormat*)format
{
    if (format.diskSize <= format.diskCapacity) return;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager hnk_enumerateContentsOfDirectoryAtPath:format.directory orderedByProperty:NSURLContentModificationDateKey ascending:YES usingBlock:^(NSURL *url, NSUInteger idx, BOOL *stop) {
        NSString *path = url.path;
        [self removeFileAtPath:path format:format];
        if (format.diskSize <= format.diskCapacity)
        {
            *stop = YES;
        }
    }];
}

- (void)removeFileAtPath:(NSString*)path format:(HNKCacheFormat*)format
{
    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
    if (attributes)
    {
        unsigned long long fileSize = attributes.fileSize;
        if ([fileManager removeItemAtPath:path error:&error])
        {
            format.diskSize -= fileSize;
        }
        else
        {
            NSLog(@"Failed to remove file with error %@", error);
        }
    }
}

- (void)saveImage:(UIImage*)image key:(NSString*)key format:(HNKCacheFormat*)format
{
    if (format.diskCapacity == 0) return;
    
    NSString *path = [self pathForKey:key format:format];
    if (image)
    {
        NSData *imageData = UIImageJPEGRepresentation(image, format.compressionQuality);
        NSError *error;
        if (![imageData writeToFile:path options:kNilOptions error:&error])
        {
            NSLog(@"Failed to write to file %@", error);
        }
        NSUInteger byteCount = imageData.length;
        format.diskSize += byteCount;
        [self controlDiskCapacityOfFormat:format];
    }
    else
    {
        [self removeFileAtPath:path format:format];
    }
}

- (void)updateAccessDateOfImage:(UIImage*)image key:(NSString*)key format:(HNKCacheFormat*)format
{
    NSString *path = [self pathForKey:key format:format];
    NSDate *now = [NSDate date];
    NSDictionary* attributes = @{NSFileModificationDate : now};
    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:path error:&error])
    {
        if ([fileManager fileExistsAtPath:path isDirectory:nil])
        {
            NSLog(@"Set attributes failed with error %@", [error localizedDescription]);
        }
        else
        {
            [self saveImage:image key:key format:format];
        }
    }
}

#pragma mark - Notifications

- (void)didReceiveMemoryWarning:(NSNotification*)notification
{
    [_memoryCaches enumerateKeysAndObjectsUsingBlock:^(id key, NSCache *cache, BOOL *stop) {
        [cache removeAllObjects];
    }];
}

@end

@implementation HNKCacheFormat

- (id)initWithName:(NSString *)name
{
    self = [super init];
    if (self)
    {
        _name = name;
        _compressionQuality = 1;
    }
    return self;
}

- (UIImage*)resizedImageFromImage:(UIImage*)originalImage
{
    const CGSize formatSize = self.size;
    CGSize resizedSize;
    switch (self.scaleMode) {
        case HNKScaleModeAspectFill:
            resizedSize = [originalImage hnk_aspectFillSizeForSize:formatSize];
            break;
        case HNKScaleModeAspectFit:
            resizedSize = [originalImage hnk_aspectFitSizeForSize:formatSize];
            break;
        case HNKScaleModeFill:
            resizedSize = formatSize;
            break;
    }
    if (!self.allowUpscaling)
    {
        CGSize originalSize = originalImage.size;
        if (resizedSize.width > originalSize.width || resizedSize.height > originalSize.height)
        {
            return originalImage;
        }
    }
    UIImage *image = [originalImage hnk_imageByScalingToSize:resizedSize];
    return image;
}

#pragma mark Private

- (NSString*)directory
{
    NSString *rootDirectory = self.cache.rootDirectory;
    NSString *directory = [rootDirectory stringByAppendingPathComponent:self.name];
    NSError *error;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error])
    {
        NSLog(@"Failed to create directory with error %@", error);
    }
    return directory;
}

@end

@implementation UIImage (hnk_utils)

- (CGSize)hnk_aspectFillSizeForSize:(CGSize)size
{
    CGFloat targetAspect = size.width / size.height;
    CGFloat sourceAspect = self.size.width / self.size.height;
    CGSize result = CGSizeZero;
    
    if (targetAspect > sourceAspect)
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    else
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    return CGSizeMake(ceil(result.width), ceil(result.height));
}

- (CGSize)hnk_aspectFitSizeForSize:(CGSize)size
{
    CGFloat targetAspect = size.width / size.height;
    CGFloat sourceAspect = self.size.width / self.size.height;
    CGSize result = CGSizeZero;
    
    if (targetAspect > sourceAspect)
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    else
    {
        result.width = size.width;
        result.height = result.width / sourceAspect;
    }
    return CGSizeMake(ceil(result.width), ceil(result.height));
}

- (UIImage *)hnk_imageByScalingToSize:(CGSize)newSize
{
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [self drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

@end

@implementation NSFileManager(hnk_utils)

- (void)hnk_enumerateContentsOfDirectoryAtPath:(NSString*)path orderedByProperty:(NSString*)property ascending:(BOOL)ascending usingBlock:(void(^)(NSURL *url, NSUInteger idx, BOOL *stop))block
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *directoryURL = [NSURL fileURLWithPath:path];
    NSError *error;
    NSArray *contents = [fileManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:@[property] options:kNilOptions error:&error];
    if (!contents)
    {
        NSLog(@"Failed to list directory with error %@", error);
        return;
    }
    contents = [contents sortedArrayUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        id value1;
        [url1 getResourceValue:&value1 forKey:property error:nil];
        id value2;
        [url2 getResourceValue:&value2 forKey:property error:nil] ;
        return ascending ? [value1 compare:value2] : [value2 compare:value1];
    }];
    [contents enumerateObjectsUsingBlock:block];
}

@end
