/* FilesOutlineViewController */

#import <Cocoa/Cocoa.h>
#import "FileSystemDoc.h"
#import "ImageAndTextCell.h"
#import "FileSizeFormatter.h"
#import "DIXOutlineView.h"

@interface FilesOutlineViewController : NSObject
{
    IBOutlet FileSystemDoc *_document;
    IBOutlet DIXOutlineView *_outlineView;
    IBOutlet NSMenu *_contextMenu;
    BOOL _syncingSelection; //YES while the selection is passed between us and the document
}

- (FileSystemDoc*) document;

- (FSItem*) rootItem;

@end
