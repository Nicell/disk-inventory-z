//
//  DIXBulkScanner.h
//  Disk Inventory Z
//
//  Parallel directory walker built on getattrlistbulk(2). One syscall returns
//  the metadata of a whole batch of directory entries, so no per-file NSURL,
//  dictionary or attribute lookup is needed. Results land in arena-allocated C
//  nodes; FSItem turns them into objects on the calling thread once the walk
//  has finished.
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#ifndef DIXBulkScanner_h
#define DIXBulkScanner_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef enum { DIXNodeFile = 0, DIXNodeFolder = 1, DIXNodePackage = 2 } DIXNodeKind;

typedef struct DIXScanNode
{
	struct DIXScanNode *parent, *first, *next;
	const char *name;
	const char *uti;			// interned, lives for the whole process
	_Atomic uint64_t logicalSize, physicalSize;
	uint32_t childCount;
	uint8_t kind;				// DIXNodeKind
	bool isAlias;				// symlink or Finder alias
	bool isHardlinkDuplicate;	// second-or-later link to an inode already charged
} DIXScanNode;

// Set of inode ids that were already charged in one scan. A scan is split into
// one walk per top-level item, and all of those walks share one set.
typedef struct DIXInodeSet DIXInodeSet;
DIXInodeSet *DIXInodeSetCreate(void);
void DIXInodeSetFree(DIXInodeSet *set);
// Returns true if the inode was not in the set yet.
bool DIXInodeSetAdd(DIXInodeSet *set, uint64_t inode);

typedef struct DIXScan DIXScan;

typedef struct
{
	const char *rootPath;
	int threads;
	bool rootIsOpaquePackage;	// only sum sizes below the root, create no nodes
	bool lookIntoPackages;		// NO: packages below the root get summed, not expanded
	DIXInodeSet *inodes;		// NULL: the walk uses a private set
	_Atomic unsigned *fileCounter, *folderCounter;	// optional live progress counters
} DIXScanOptions;

DIXScan *DIXScanStart( const DIXScanOptions *options );

// Blocks for at most timeoutMillis. Returns true once all workers are done.
bool DIXScanWait( DIXScan *scan, unsigned timeoutMillis );

void DIXScanCancel( DIXScan *scan );

// Copies the directory most recently entered near the top of the tree.
// Returns false if there is nothing new since the last call.
bool DIXScanCopyCurrentPath( DIXScan *scan, char *buffer, unsigned bufferSize );

// true if the volume cannot do bulk reads at all, so the caller has to fall
// back to the NSDirectoryEnumerator walker. Valid after DIXScanWait returned true.
bool DIXScanIsUnsupported( DIXScan *scan );

// Joins the workers, settles hardlinks and sums and sorts the tree.
// The returned tree is owned by the scan and freed with it.
DIXScanNode *DIXScanFinish( DIXScan *scan );

void DIXScanFree( DIXScan *scan );

#endif
