//
//  DIXBulkScanner.m
//  Disk Inventory Z
//
//  See DIXBulkScanner.h.
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "DIXBulkScanner.h"

#include <ctype.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <unistd.h>

#define BULK_BUFFER_SIZE	(64 * 1024)
#define ARENA_CHUNK_SIZE	(4 * 1024 * 1024)
#define EXTENSION_CACHE_SIZE 512
#define EXTENSION_MAX_LENGTH 24
#define PROGRESS_PATH_DEPTH	4

#define FINDER_FLAG_IS_ALIAS	0x8000
#define FINDER_FLAG_HAS_BUNDLE	0x2000

//================ arena ======================================================

typedef struct ArenaChunk { struct ArenaChunk *next; } ArenaChunk;
typedef struct { ArenaChunk *chunks; char *cursor; size_t left; } Arena;

static void *ArenaAlloc( Arena *arena, size_t size )
{
	size = (size + 7) & ~(size_t)7;
	if ( size > arena->left )
	{
		size_t chunkSize = size + sizeof(ArenaChunk) > ARENA_CHUNK_SIZE ? size + sizeof(ArenaChunk) : ARENA_CHUNK_SIZE;
		ArenaChunk *chunk = malloc( chunkSize );
		chunk->next = arena->chunks;
		arena->chunks = chunk;
		arena->cursor = (char*)(chunk + 1);
		arena->left = chunkSize - sizeof(ArenaChunk);
	}
	void *result = arena->cursor;
	arena->cursor += size;
	arena->left -= size;
	return result;
}

static void ArenaFree( Arena *arena )
{
	ArenaChunk *chunk = arena->chunks;
	while ( chunk != NULL )
	{
		ArenaChunk *next = chunk->next;
		free( chunk );
		chunk = next;
	}
	memset( arena, 0, sizeof(*arena) );
}

//================ inode set ==================================================

struct DIXInodeSet
{
	os_unfair_lock lock;
	uint64_t *slots;
	size_t capacity, count;
};

DIXInodeSet *DIXInodeSetCreate( void )
{
	DIXInodeSet *set = calloc( 1, sizeof(DIXInodeSet) );
	set->lock = OS_UNFAIR_LOCK_INIT;
	return set;
}

void DIXInodeSetFree( DIXInodeSet *set )
{
	if ( set != NULL )
	{
		free( set->slots );
		free( set );
	}
}

// Id 0 is never a valid inode.
bool DIXInodeSetAdd( DIXInodeSet *set, uint64_t inode )
{
	const uint64_t mix = 0x9E3779B97F4A7C15ull;
	bool added = true;

	os_unfair_lock_lock( &set->lock );
	if ( (set->count + 1) * 2 > set->capacity )
	{
		size_t newCapacity = set->capacity != 0 ? set->capacity * 2 : 4096;
		uint64_t *newSlots = calloc( newCapacity, sizeof(uint64_t) );
		for ( size_t i = 0; i < set->capacity; i++ )
		{
			if ( set->slots[i] == 0 )
				continue;
			size_t slot = (set->slots[i] * mix) % newCapacity;
			while ( newSlots[slot] != 0 )
				slot = (slot + 1) % newCapacity;
			newSlots[slot] = set->slots[i];
		}
		free( set->slots );
		set->slots = newSlots;
		set->capacity = newCapacity;
	}
	size_t slot = (inode * mix) % set->capacity;
	while ( set->slots[slot] != 0 && set->slots[slot] != inode )
		slot = (slot + 1) % set->capacity;
	if ( set->slots[slot] != 0 )
		added = false;
	else
	{
		set->slots[slot] = inode;
		set->count++;
	}
	os_unfair_lock_unlock( &set->lock );

	return added;
}

//================ file types =================================================

typedef struct { const char *uti; bool isPackage; } TypeInfo;
typedef struct { char extension[EXTENSION_MAX_LENGTH]; bool isFolder, used; TypeInfo info; } ExtensionCacheEntry;

static os_unfair_lock g_typeLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *g_extensionTypes = nil;

static const char *InternUTI( NSString *uti )
{
	static NSMutableDictionary *interned = nil;
	const char *result;

	os_unfair_lock_lock( &g_typeLock );
	if ( interned == nil )
		interned = [[NSMutableDictionary alloc] init];
	NSValue *value = interned[uti];
	if ( value != nil )
		result = [value pointerValue];
	else
	{
		result = strdup( [uti UTF8String] );
		interned[uti] = [NSValue valueWithPointer: result];
	}
	os_unfair_lock_unlock( &g_typeLock );

	return result;
}

static TypeInfo LookUpExtension( const char *extension, bool isFolder )
{
	TypeInfo info;
	NSString *extensionString = [NSString stringWithUTF8String: extension];
	NSString *key = [(isFolder ? @"d." : @"f.") stringByAppendingString: extensionString != nil ? extensionString : @""];

	os_unfair_lock_lock( &g_typeLock );
	if ( g_extensionTypes == nil )
		g_extensionTypes = [[NSMutableDictionary alloc] init];
	NSValue *cached = g_extensionTypes[key];
	if ( cached != nil )
		[cached getValue: &info];
	os_unfair_lock_unlock( &g_typeLock );

	if ( cached != nil )
		return info;

	UTType *type = extensionString == nil ? nil
				 : [UTType typeWithFilenameExtension: extensionString
									conformingToType: isFolder ? UTTypeDirectory : UTTypeData];
	if ( type == nil )
		type = isFolder ? UTTypeFolder : UTTypeData;

	info.uti = InternUTI( type.identifier );
	info.isPackage = isFolder && [type conformsToType: UTTypePackage];

	os_unfair_lock_lock( &g_typeLock );
	g_extensionTypes[key] = [NSValue value: &info withObjCType: @encode(TypeInfo)];
	os_unfair_lock_unlock( &g_typeLock );

	return info;
}

// NSURLTypeIdentifierKey special-cases these extensionless names. It goes by
// the name alone (a binary file called LICENSE still is "plain text"), and the
// name beats the executable bit.
static const char *UTIForSpecialName( const char *name )
{
	static const char * const textNames[] = { "LICENSE", "README", "COPYING", "AUTHORS", "NEWS",
											  "INSTALL", "ChangeLog", "THANKS" };
	static const char * const makeNames[] = { "Makefile", "makefile", "GNUmakefile" };

	for ( size_t i = 0; i < sizeof(textNames) / sizeof(textNames[0]); i++ )
		if ( strcmp( name, textNames[i] ) == 0 )
			return "public.plain-text";
	for ( size_t i = 0; i < sizeof(makeNames) / sizeof(makeNames[0]); i++ )
		if ( strcmp( name, makeNames[i] ) == 0 )
			return "public.make-source";
	if ( strcmp( name, ".DS_Store" ) == 0 )
		return "dyn.ah62d4rv4gk8wakbaea";
	return NULL;
}

static TypeInfo TypeInfoForEntry( ExtensionCacheEntry *cache, const char *name, bool isFolder, bool isExecutable )
{
	const char *dot = strrchr( name, '.' );
	const char *extension = ( dot != NULL && dot != name && dot[1] != '\0' ) ? dot + 1 : NULL;

	if ( extension == NULL )
	{
		TypeInfo info = { isFolder ? "public.folder" : NULL, false };
		if ( !isFolder )
		{
			info.uti = UTIForSpecialName( name );
			if ( info.uti == NULL )
				info.uti = isExecutable ? "public.unix-executable" : "public.data";
		}
		return info;
	}

	size_t length = strlen( extension );
	if ( length >= EXTENSION_MAX_LENGTH )
	{
		TypeInfo info;
		@autoreleasepool { info = LookUpExtension( extension, isFolder ); }
		return info;
	}

	unsigned hash = isFolder ? 1 : 0;
	for ( const char *p = extension; *p != '\0'; p++ )
		hash = hash * 31 + (unsigned char)*p;

	ExtensionCacheEntry *entry = &cache[hash % EXTENSION_CACHE_SIZE];
	if ( entry->used && entry->isFolder == isFolder && strcmp( entry->extension, extension ) == 0 )
		return entry->info;

	TypeInfo info;
	@autoreleasepool { info = LookUpExtension( extension, isFolder ); }

	memcpy( entry->extension, extension, length + 1 );
	entry->isFolder = isFolder;
	entry->used = true;
	entry->info = info;
	return info;
}

//================ scan state =================================================

typedef struct { DIXScanNode *directory; DIXScanNode *owner; char *path; unsigned depth; } Task;

typedef struct
{
	uint64_t inode;
	DIXScanNode *target;	// the file's node, or the package owning it
	uint64_t logicalSize, physicalSize;
	char *path;
	bool targetIsFile;
} HardlinkRecord;

typedef struct
{
	DIXScan *scan;
	pthread_t thread;
	Arena arena;
	HardlinkRecord *hardlinks;
	size_t hardlinkCount, hardlinkCapacity;
} Worker;

struct DIXScan
{
	DIXScanOptions options;
	char *rootPathCopy;
	DIXScanNode *root;
	bool ownsInodes;

	pthread_mutex_t queueLock;
	pthread_cond_t queueCondition;
	Task *queue;
	size_t queueCount, queueCapacity;
	int activeWorkers;
	_Atomic int idleWorkers;

	_Atomic bool cancelled, unsupported;
	_Atomic int runningWorkers;
	dispatch_semaphore_t allDone;
	bool joined, finished;

	Worker *workers;
	int workerCount;

	os_unfair_lock pathLock;
	char currentPath[1024];
	bool currentPathIsNew;
};

static void QueuePush( DIXScan *scan, const Task *tasks, size_t count )
{
	pthread_mutex_lock( &scan->queueLock );
	if ( scan->queueCount + count > scan->queueCapacity )
	{
		scan->queueCapacity = (scan->queueCount + count) * 2;
		scan->queue = realloc( scan->queue, scan->queueCapacity * sizeof(Task) );
	}
	memcpy( scan->queue + scan->queueCount, tasks, count * sizeof(Task) );
	scan->queueCount += count;
	pthread_cond_broadcast( &scan->queueCondition );
	pthread_mutex_unlock( &scan->queueLock );
}

// Takes a task from the shared queue. Returns false when the walk is over:
// the queue is empty and no other worker could add to it any more.
static bool QueuePop( DIXScan *scan, Task *task )
{
	pthread_mutex_lock( &scan->queueLock );
	scan->activeWorkers--;
	atomic_fetch_add( &scan->idleWorkers, 1 );
	while ( scan->queueCount == 0 && scan->activeWorkers > 0 )
		pthread_cond_wait( &scan->queueCondition, &scan->queueLock );

	bool gotTask = scan->queueCount > 0;
	if ( gotTask )
	{
		*task = scan->queue[--scan->queueCount];
		scan->activeWorkers++;
	}
	else
		pthread_cond_broadcast( &scan->queueCondition );
	atomic_fetch_sub( &scan->idleWorkers, 1 );
	pthread_mutex_unlock( &scan->queueLock );

	return gotTask;
}

static char *JoinPath( const char *directory, size_t directoryLength, const char *name, size_t nameLength )
{
	bool isRootDirectory = directoryLength == 1 && directory[0] == '/';
	size_t prefixLength = isRootDirectory ? 0 : directoryLength;
	char *path = malloc( prefixLength + nameLength + 2 );
	memcpy( path, directory, prefixLength );
	path[prefixLength] = '/';
	memcpy( path + prefixLength + 1, name, nameLength + 1 );
	return path;
}

// Only LaunchServices knows these: a folder with an unregistered extension can
// still count as a package, and an alias or mount point has a type of its own.
static void AskNSURL( const char *path, bool isFolder, bool wantsPackage, bool *isPackage, const char **uti )
{
	@autoreleasepool
	{
		NSURL *url = [NSURL fileURLWithFileSystemRepresentation: path isDirectory: isFolder relativeToURL: nil];
		if ( wantsPackage )
		{
			NSNumber *value = nil;
			[url getResourceValue: &value forKey: NSURLIsPackageKey error: nil];
			*isPackage = [value boolValue];
		}
		if ( uti != NULL )
		{
			NSString *value = nil;
			[url getResourceValue: &value forKey: NSURLTypeIdentifierKey error: nil];
			if ( value != nil )
				*uti = InternUTI( value );
		}
	}
}

static bool HasExtension( const char *name, const char *extension )
{
	const char *dot = strrchr( name, '.' );
	return dot != NULL && strcmp( dot + 1, extension ) == 0;
}

static void *WorkerMain( void *argument )
{
	Worker *worker = argument;
	DIXScan *scan = worker->scan;

	@autoreleasepool
	{
		ExtensionCacheEntry *typeCache = calloc( EXTENSION_CACHE_SIZE, sizeof(ExtensionCacheEntry) );
		char *buffer = malloc( BULK_BUFFER_SIZE );
		size_t localCapacity = 1024, localCount = 0;
		Task *local = malloc( localCapacity * sizeof(Task) );
		unsigned directoriesSinceProgress = 0;

		struct attrlist attributes = { 0 };
		attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
		attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE
							  | ATTR_CMN_FNDRINFO | ATTR_CMN_ACCESSMASK | ATTR_CMN_FILEID;
		attributes.dirattr = ATTR_DIR_MOUNTSTATUS;
		attributes.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

		for ( ;; )
		{
			Task task;
			if ( localCount > 0 )
				task = local[--localCount];
			else if ( !QueuePop( scan, &task ) )
				break;

			if ( atomic_load_explicit( &scan->cancelled, memory_order_relaxed ) )
			{
				free( task.path );
				continue;
			}

			size_t pathLength = strlen( task.path );
			unsigned filesHere = 0, foldersHere = 0;

			if ( task.depth <= PROGRESS_PATH_DEPTH && ++directoriesSinceProgress >= 16 )
			{
				directoriesSinceProgress = 0;
				os_unfair_lock_lock( &scan->pathLock );
				strlcpy( scan->currentPath, task.path, sizeof(scan->currentPath) );
				scan->currentPathIsNew = true;
				os_unfair_lock_unlock( &scan->pathLock );
			}

			int directory = open( task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC );
			if ( directory < 0 )
			{
				// ELOOP/ENOTDIR: the root may be a symlink, which is not an error
				free( task.path );
				continue;
			}

			for ( ;; )
			{
				int entryCount = getattrlistbulk( directory, &attributes, buffer, BULK_BUFFER_SIZE, 0 );
				if ( entryCount < 0 && task.depth == 0 && ( errno == ENOTSUP || errno == EINVAL ) )
				{
					atomic_store( &scan->unsupported, true );
					break;
				}
				if ( entryCount <= 0 )
					break;

				char *entry = buffer;
				for ( int i = 0; i < entryCount; i++ )
				{
					char *record = entry;
					uint32_t length;
					memcpy( &length, record, sizeof(length) );
					entry += length;

					// The kernel only packs what it reports in "returned".
					char *field = record + sizeof(uint32_t);
					attribute_set_t returned;
					memcpy( &returned, field, sizeof(returned) );
					field += sizeof(returned);

					uint32_t entryError = 0;
					if ( returned.commonattr & ATTR_CMN_ERROR )
					{
						memcpy( &entryError, field, sizeof(entryError) );
						field += sizeof(entryError);
					}
					if ( entryError != 0 || !( returned.commonattr & ATTR_CMN_NAME ) )
						continue;

					attrreference_t nameReference;
					memcpy( &nameReference, field, sizeof(nameReference) );
					const char *name = field + nameReference.attr_dataoffset;
					field += sizeof(nameReference);

					fsobj_type_t objectType = VNON;
					if ( returned.commonattr & ATTR_CMN_OBJTYPE )
					{
						memcpy( &objectType, field, sizeof(objectType) );
						field += sizeof(objectType);
					}
					uint8_t finderInfo[32] = { 0 };
					if ( returned.commonattr & ATTR_CMN_FNDRINFO )
					{
						memcpy( finderInfo, field, sizeof(finderInfo) );
						field += sizeof(finderInfo);
					}
					uint32_t accessMask = 0;
					if ( returned.commonattr & ATTR_CMN_ACCESSMASK )
					{
						memcpy( &accessMask, field, sizeof(accessMask) );
						field += sizeof(accessMask);
					}
					uint64_t inode = 0;
					if ( returned.commonattr & ATTR_CMN_FILEID )
					{
						memcpy( &inode, field, sizeof(inode) );
						field += sizeof(inode);
					}
					uint32_t mountStatus = 0;
					if ( returned.dirattr & ATTR_DIR_MOUNTSTATUS )
					{
						memcpy( &mountStatus, field, sizeof(mountStatus) );
						field += sizeof(mountStatus);
					}
					uint32_t linkCount = 1;
					if ( returned.fileattr & ATTR_FILE_LINKCOUNT )
					{
						memcpy( &linkCount, field, sizeof(linkCount) );
						field += sizeof(linkCount);
					}
					uint64_t logicalSize = 0, physicalSize = 0;
					if ( returned.fileattr & ATTR_FILE_TOTALSIZE )
					{
						memcpy( &logicalSize, field, sizeof(logicalSize) );
						field += sizeof(logicalSize);
					}
					if ( returned.fileattr & ATTR_FILE_ALLOCSIZE )
					{
						memcpy( &physicalSize, field, sizeof(physicalSize) );
						field += sizeof(physicalSize);
					}

					// .nofollow / .resolve: macOS 26 magic directories that re-expose
					// the whole file system. /Volumes: cross-mounts the boot volume.
					if ( name[0] == '.' && ( strcmp( name, ".nofollow" ) == 0 || strcmp( name, ".resolve" ) == 0 ) )
						continue;
					if ( pathLength == 1 && task.path[0] == '/' && strcmp( name, "Volumes" ) == 0 )
						continue;

					bool isFolder = objectType == VDIR;
					bool isMountPoint = isFolder && ( mountStatus & DIR_MNTSTATUS_MNTPOINT );
					bool isHardlink = objectType == VREG && linkCount > 1 && inode != 0;
					size_t nameLength = strlen( name );

					if ( task.owner != NULL )
					{
						// Inside an opaque package: no nodes, just credit the owner.
						if ( isFolder )
						{
							if ( !isMountPoint )
							{
								if ( localCount == localCapacity )
									local = realloc( local, (localCapacity *= 2) * sizeof(Task) );
								local[localCount++] = (Task){ NULL, task.owner,
									JoinPath( task.path, pathLength, name, nameLength ), task.depth + 1 };
							}
						}
						else if ( isHardlink )
						{
							if ( worker->hardlinkCount == worker->hardlinkCapacity )
							{
								worker->hardlinkCapacity = worker->hardlinkCapacity != 0 ? worker->hardlinkCapacity * 2 : 256;
								worker->hardlinks = realloc( worker->hardlinks, worker->hardlinkCapacity * sizeof(HardlinkRecord) );
							}
							worker->hardlinks[worker->hardlinkCount++] = (HardlinkRecord){ inode, task.owner, logicalSize, physicalSize,
								JoinPath( task.path, pathLength, name, nameLength ), false };
						}
						else
						{
							atomic_fetch_add_explicit( &task.owner->logicalSize, logicalSize, memory_order_relaxed );
							atomic_fetch_add_explicit( &task.owner->physicalSize, physicalSize, memory_order_relaxed );
						}
						continue;
					}

					DIXScanNode *node = ArenaAlloc( &worker->arena, sizeof(DIXScanNode) + nameLength + 1 );
					char *nameCopy = (char*)(node + 1);
					memcpy( nameCopy, name, nameLength + 1 );

					uint16_t finderFlags = (uint16_t)( ( finderInfo[8] << 8 ) | finderInfo[9] );
					bool isExecutable = objectType == VREG && ( accessMask & 0111 ) != 0;
					bool isFinderAlias = ( finderFlags & FINDER_FLAG_IS_ALIAS ) != 0 && !isFolder;
					bool isPackage = false;
					const char *uti;

					if ( objectType == VLNK )
						uti = "public.symlink";
					else
					{
						TypeInfo info = TypeInfoForEntry( typeCache, nameCopy, isFolder, isExecutable );
						uti = info.uti;
						isPackage = isFolder && ( info.isPackage || ( finderFlags & FINDER_FLAG_HAS_BUNDLE ) != 0 );

						if ( strncmp( uti, "dyn.", 4 ) == 0 && isFolder && !isPackage )
						{
							if ( !HasExtension( nameCopy, "lproj" ) )
							{
								char *entryPath = JoinPath( task.path, pathLength, nameCopy, nameLength );
								AskNSURL( entryPath, true, true, &isPackage, NULL );
								free( entryPath );
							}
							if ( !isPackage )
								uti = "public.folder";
						}
						if ( isFinderAlias || isMountPoint )
						{
							char *entryPath = JoinPath( task.path, pathLength, nameCopy, nameLength );
							AskNSURL( entryPath, isFolder, false, NULL, &uti );
							free( entryPath );
						}
					}

					node->parent = task.directory;
					node->first = NULL;
					node->childCount = 0;
					node->name = nameCopy;
					node->uti = uti;
					node->kind = !isFolder ? DIXNodeFile : isPackage ? DIXNodePackage : DIXNodeFolder;
					node->isAlias = objectType == VLNK || isFinderAlias;
					node->isHardlinkDuplicate = false;
					atomic_init( &node->logicalSize, isHardlink ? 0 : logicalSize );
					atomic_init( &node->physicalSize, isHardlink ? 0 : physicalSize );

					// No lock: only this worker holds task.directory right now.
					node->next = task.directory->first;
					task.directory->first = node;
					task.directory->childCount++;

					if ( isHardlink )
					{
						if ( worker->hardlinkCount == worker->hardlinkCapacity )
						{
							worker->hardlinkCapacity = worker->hardlinkCapacity != 0 ? worker->hardlinkCapacity * 2 : 256;
							worker->hardlinks = realloc( worker->hardlinks, worker->hardlinkCapacity * sizeof(HardlinkRecord) );
						}
						worker->hardlinks[worker->hardlinkCount++] = (HardlinkRecord){ inode, node, logicalSize, physicalSize,
							JoinPath( task.path, pathLength, nameCopy, nameLength ), true };
					}

					if ( isFolder )
					{
						foldersHere++;
						if ( !isMountPoint )
						{
							bool opaque = isPackage && !scan->options.lookIntoPackages;
							if ( localCount == localCapacity )
								local = realloc( local, (localCapacity *= 2) * sizeof(Task) );
							local[localCount++] = (Task){ node, opaque ? node : NULL,
								JoinPath( task.path, pathLength, nameCopy, nameLength ), task.depth + 1 };
						}
					}
					else
						filesHere++;
				}
			}

			close( directory );
			free( task.path );

			if ( filesHere != 0 && scan->options.fileCounter != NULL )
				atomic_fetch_add_explicit( scan->options.fileCounter, filesHere, memory_order_relaxed );
			if ( foldersHere != 0 && scan->options.folderCounter != NULL )
				atomic_fetch_add_explicit( scan->options.folderCounter, foldersHere, memory_order_relaxed );

			// Share work while other workers are starving.
			if ( localCount > 1 && atomic_load_explicit( &scan->idleWorkers, memory_order_relaxed ) > 0 )
			{
				size_t give = localCount / 2;
				QueuePush( scan, local, give );
				memmove( local, local + give, (localCount - give) * sizeof(Task) );
				localCount -= give;
			}
		}

		free( buffer );
		free( typeCache );
		free( local );
	}

	if ( atomic_fetch_sub( &scan->runningWorkers, 1 ) == 1 )
		dispatch_semaphore_signal( scan->allDone );

	return NULL;
}

//================ public API =================================================

DIXScan *DIXScanStart( const DIXScanOptions *options )
{
	DIXScan *scan = calloc( 1, sizeof(DIXScan) );
	scan->options = *options;
	scan->rootPathCopy = strdup( options->rootPath );
	scan->options.rootPath = scan->rootPathCopy;
	scan->options.threads = options->threads > 0 ? options->threads : 1;
	scan->pathLock = OS_UNFAIR_LOCK_INIT;
	pthread_mutex_init( &scan->queueLock, NULL );
	pthread_cond_init( &scan->queueCondition, NULL );
	scan->allDone = dispatch_semaphore_create( 0 );

	if ( scan->options.inodes == NULL )
	{
		scan->options.inodes = DIXInodeSetCreate();
		scan->ownsInodes = true;
	}

	scan->root = calloc( 1, sizeof(DIXScanNode) );
	scan->root->name = scan->rootPathCopy;
	scan->root->uti = "public.folder";
	scan->root->kind = options->rootIsOpaquePackage ? DIXNodePackage : DIXNodeFolder;

	Task first = { scan->root, options->rootIsOpaquePackage ? scan->root : NULL, strdup( options->rootPath ), 0 };
	QueuePush( scan, &first, 1 );

	scan->workerCount = scan->options.threads;
	scan->workers = calloc( (size_t)scan->workerCount, sizeof(Worker) );
	scan->activeWorkers = scan->workerCount;
	atomic_store( &scan->runningWorkers, scan->workerCount );

	pthread_attr_t threadAttributes;
	pthread_attr_init( &threadAttributes );
	pthread_attr_set_qos_class_np( &threadAttributes, QOS_CLASS_USER_INITIATED, 0 );
	for ( int i = 0; i < scan->workerCount; i++ )
	{
		scan->workers[i].scan = scan;
		pthread_create( &scan->workers[i].thread, &threadAttributes, WorkerMain, &scan->workers[i] );
	}
	pthread_attr_destroy( &threadAttributes );

	return scan;
}

bool DIXScanWait( DIXScan *scan, unsigned timeoutMillis )
{
	if ( scan->joined )
		return true;

	if ( dispatch_semaphore_wait( scan->allDone, dispatch_time( DISPATCH_TIME_NOW, (int64_t)timeoutMillis * NSEC_PER_MSEC ) ) != 0 )
		return false;

	for ( int i = 0; i < scan->workerCount; i++ )
		pthread_join( scan->workers[i].thread, NULL );
	scan->joined = true;
	return true;
}

void DIXScanCancel( DIXScan *scan )
{
	atomic_store( &scan->cancelled, true );
}

bool DIXScanCopyCurrentPath( DIXScan *scan, char *buffer, unsigned bufferSize )
{
	bool isNew;
	os_unfair_lock_lock( &scan->pathLock );
	isNew = scan->currentPathIsNew;
	if ( isNew )
	{
		strlcpy( buffer, scan->currentPath, bufferSize );
		scan->currentPathIsNew = false;
	}
	os_unfair_lock_unlock( &scan->pathLock );
	return isNew;
}

bool DIXScanIsUnsupported( DIXScan *scan )
{
	return atomic_load( &scan->unsupported );
}

static int CompareHardlinks( const void *a, const void *b )
{
	const HardlinkRecord *x = a, *y = b;
	if ( x->inode != y->inode )
		return x->inode < y->inode ? -1 : 1;
	return strcmp( x->path, y->path );
}

// The walk order depends on thread timing, so settle which link gets charged
// afterwards: the first path of each inode, sorted. That makes a scan repeatable.
static void SettleHardlinks( DIXScan *scan )
{
	size_t total = 0;
	for ( int i = 0; i < scan->workerCount; i++ )
		total += scan->workers[i].hardlinkCount;
	if ( total == 0 )
		return;

	HardlinkRecord *records = malloc( total * sizeof(HardlinkRecord) );
	size_t filled = 0;
	for ( int i = 0; i < scan->workerCount; i++ )
	{
		Worker *worker = &scan->workers[i];
		if ( worker->hardlinkCount != 0 )
			memcpy( records + filled, worker->hardlinks, worker->hardlinkCount * sizeof(HardlinkRecord) );
		filled += worker->hardlinkCount;
		free( worker->hardlinks );
		worker->hardlinks = NULL;
		worker->hardlinkCount = 0;
	}
	qsort( records, total, sizeof(HardlinkRecord), CompareHardlinks );

	for ( size_t i = 0; i < total; )
	{
		size_t end = i;
		while ( end < total && records[end].inode == records[i].inode )
			end++;

		bool charged = DIXInodeSetAdd( scan->options.inodes, records[i].inode );
		for ( size_t k = i; k < end; k++ )
		{
			HardlinkRecord *record = &records[k];
			if ( charged && k == i )
			{
				atomic_fetch_add_explicit( &record->target->logicalSize, record->logicalSize, memory_order_relaxed );
				atomic_fetch_add_explicit( &record->target->physicalSize, record->physicalSize, memory_order_relaxed );
			}
			else if ( record->targetIsFile )
				record->target->isHardlinkDuplicate = true;
			free( record->path );
		}
		i = end;
	}
	free( records );
}

// Matches -compareAsFilesystemName: for ASCII: case-insensitive, digit runs by value.
static int CompareNames( const char *a, const char *b )
{
	for ( ;; )
	{
		unsigned char x = (unsigned char)*a, y = (unsigned char)*b;
		if ( x == '\0' || y == '\0' )
			return x == y ? 0 : ( x == '\0' ? -1 : 1 );

		if ( isdigit( x ) && isdigit( y ) )
		{
			while ( *a == '0' ) a++;
			while ( *b == '0' ) b++;
			const char *startA = a, *startB = b;
			while ( isdigit( (unsigned char)*a ) ) a++;
			while ( isdigit( (unsigned char)*b ) ) b++;
			long lengthA = a - startA, lengthB = b - startB;
			if ( lengthA != lengthB )
				return lengthA < lengthB ? -1 : 1;
			int digits = strncmp( startA, startB, (size_t)lengthA );
			if ( digits != 0 )
				return digits;
			continue;
		}

		int lowerX = tolower( x ), lowerY = tolower( y );
		if ( lowerX != lowerY )
			return lowerX < lowerY ? -1 : 1;
		a++;
		b++;
	}
}

// Biggest first. Equal sizes run Z to A because FSItem's -compareSizeDescendingly:
// flips the whole result of -compareSize:, name tie-break included.
static int CompareNodes( const void *a, const void *b )
{
	const DIXScanNode *x = *(DIXScanNode * const *)a, *y = *(DIXScanNode * const *)b;
	uint64_t sizeX = atomic_load_explicit( &((DIXScanNode*)x)->physicalSize, memory_order_relaxed );
	uint64_t sizeY = atomic_load_explicit( &((DIXScanNode*)y)->physicalSize, memory_order_relaxed );
	if ( sizeX != sizeY )
		return sizeX > sizeY ? -1 : 1;
	return -CompareNames( x->name, y->name );
}

static void SumAndSort( DIXScanNode *node )
{
	if ( node->kind == DIXNodeFile || node->childCount == 0 )
		return;

	uint64_t logicalSize = 0, physicalSize = 0;
	DIXScanNode **children = malloc( node->childCount * sizeof(DIXScanNode*) );
	uint32_t i = 0;
	for ( DIXScanNode *child = node->first; child != NULL; child = child->next )
	{
		SumAndSort( child );
		logicalSize += atomic_load_explicit( &child->logicalSize, memory_order_relaxed );
		physicalSize += atomic_load_explicit( &child->physicalSize, memory_order_relaxed );
		children[i++] = child;
	}
	qsort( children, node->childCount, sizeof(DIXScanNode*), CompareNodes );

	node->first = children[0];
	for ( i = 0; i + 1 < node->childCount; i++ )
		children[i]->next = children[i + 1];
	children[node->childCount - 1]->next = NULL;
	free( children );

	atomic_store_explicit( &node->logicalSize, logicalSize, memory_order_relaxed );
	atomic_store_explicit( &node->physicalSize, physicalSize, memory_order_relaxed );
}

DIXScanNode *DIXScanFinish( DIXScan *scan )
{
	while ( !DIXScanWait( scan, 1000 ) )
		;

	if ( !scan->finished )
	{
		scan->finished = true;
		SettleHardlinks( scan );
		SumAndSort( scan->root );
	}
	return scan->root;
}

void DIXScanFree( DIXScan *scan )
{
	if ( scan == NULL )
		return;

	while ( !DIXScanWait( scan, 1000 ) )
		;

	for ( int i = 0; i < scan->workerCount; i++ )
	{
		for ( size_t k = 0; k < scan->workers[i].hardlinkCount; k++ )
			free( scan->workers[i].hardlinks[k].path );
		free( scan->workers[i].hardlinks );
		ArenaFree( &scan->workers[i].arena );
	}
	free( scan->workers );
	free( scan->root );
	free( scan->queue );
	free( scan->rootPathCopy );
	if ( scan->ownsInodes )
		DIXInodeSetFree( scan->options.inodes );
	pthread_mutex_destroy( &scan->queueLock );
	pthread_cond_destroy( &scan->queueCondition );
	dispatch_release( scan->allDone );
	free( scan );
}
