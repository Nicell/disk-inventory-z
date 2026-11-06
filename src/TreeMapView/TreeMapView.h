//
//  TreeMapView.h
//  TreeMapView
//
//  Created by Tjark Derlien on Mon Sep 29 2003.
//  Copyright 2003 Tjark Derlien. All rights reserved.
//

//The API of the TreeMapView is similar to the one of NSOutlineView,
//so the basic use and the implementation of the data source is
//hopefully not so complicated.

#import <Cocoa/Cocoa.h>
#import "TMVItem.h"

typedef TMVItem* TMVCellId;

extern NSString *TreeMapViewDidRenderNotification;

@interface TreeMapView : NSView <NSViewToolTipOwner>
{
    TMVItem *_rootItemRenderer;
    IBOutlet id delegate;
    IBOutlet id dataSource;
    TMVItem *_selectedRenderer;
    NSSet *_additionalSelectedItems;
    NSMutableArray *_additionalSelectedRenderers;
    NSEventModifierFlags _selectionClickModifiers;

    // background rendering, see -reloadDataInBackground
    BOOL _renderInProgress;
    BOOL _renderAbandoned;
    _Atomic BOOL _renderCancelled;
    unsigned _renderGeneration;
    dispatch_group_t _renderGroup;
    _Atomic CGFloat _layoutScale;
    TMVItem *_touchedRenderer;
    NSBitmapImageRep *_cachedContent;
	id _zoomer;
}

- (void) invalidateCanvasCache; //just delete the cached view content
- (void) reloadData;
- (void) reloadDataInBackground;
	//lays out and draws on another thread while the old picture stays up, then posts
	//TreeMapViewDidRenderNotification. Until then there are no cells to hit or select.
	//The data source and delegate get called on that thread, so nothing they read may
	//change until the render is done: call -cancelBackgroundRender before changing it.
- (void) cancelBackgroundRender;
	//returns once the other thread has stopped touching data source and delegate.
	//If no reload follows, the next draw does one.
- (BOOL) backgroundRenderCancelled; //any thread
- (CGFloat) backingScaleForLayout; //any thread
- (void) reloadAndPerformZoomIntoItem: (NSArray*) path;
	//before relaod, a zoom in effect is shown
	//"path" identifies the data item in which will be zoomed;
	//the path has to be relative to the old root (root BEFORE reload)
	//(<old root><child1><child2><itemtoZoomIn>)
- (void) reloadAndPerformZoomOutofItem: (NSArray*) path;
	//before relaod, a zoom out effect is shown
	//"path" identifies the data item out of which will be zoomed;
	//the path has to be relative to the new root (root AFTER the reload)
	//(<new root><child1><child2><itemtoZoomOut>)
- (BOOL) zoomingInProgress;
    //indicates whether the view is currently zooming in or out,
    //so UI commands can be disabled which are not available while zooming

- (TMVCellId) cellIdByPoint: (NSPoint) point inViewCoords: (BOOL) viewCoords;
	//does a hit test; if "viewCoords" is false, "point" is considered to be in window coordinates
- (id) itemByCellId: (TMVCellId) cellId;
	//returns the data item associated with a specific tree map cell (as provided by data source)

- (id) selectedItem;
	//returns selected data item
- (void) selectItemByCellId: (TMVCellId) cellId;
	//selects a treemap cell
- (void) selectItemByPathToItem: (NSArray*) path;
- (void) setAdditionalSelectedItems: (NSSet*) items;
	//highlights these data items too; only the data source knows what they mean together
- (NSEventModifierFlags) takeSelectionClickModifiers;
	//Command or Shift, if the selection change being notified came from such a click; reading clears it
	//item to select is identified by path from root to item in question (<root><child1><child2><itemtoSelect>)

- (NSRect) itemRectByCellId: (TMVCellId) cellId;
	//rect of treemap cell in view coords
- (NSRect) itemRectByPathToItem: (NSArray*) path;
	//rect in view coords; item is identified by path from root to item in question
	//(<root><child1><child2><item>)

- (void) benchmarkLayoutCalculationWithImageSize: (NSSize) size count: (unsigned) count;
	//does the layout calculation "count" times for a window size of "size" with current display data
	//(no drawing is done and the state of the TreemapVite is not changed);
	//the time calculation has to be done by the caller
- (void) benchmarkRenderingWithImageSize: (NSSize) size count: (unsigned) count;
	//does the rendering "count" times for a window size of "size" with current display data
	//(no drawing is done and the state of the TreemapVite is not changed);
	//the time calculation has to be done by the caller

@end

// Data Source Note: Specifying nil as the item will refer to the "root" item.
// (there must be one (and only one!) root item)
@interface NSObject(TreeMapViewDataSource)
// required
- (id) treeMapView: (TreeMapView*) view child: (NSUInteger) index ofItem: (id) item;
- (BOOL) treeMapView: (TreeMapView*) view isNode: (id) item;
- (unsigned) treeMapView: (TreeMapView*) view numberOfChildrenOfItem: (id) item;
- (unsigned long long) treeMapView: (TreeMapView*) view weightByItem: (id) item;
@end

/* optional delegate methods */
@interface NSObject(TreeMapViewDelegate)
- (NSString*) treeMapView: (TreeMapView*) view getToolTipByItem: (id) item;
- (void) treeMapView: (TreeMapView*) view willDisplayItem: (id) item withRenderer: (TMVItem*) renderer;
- (BOOL) treeMapView: (TreeMapView*) view shouldSelectItem: (id) item;
- (void) treeMapView: (TreeMapView*) view willShowMenuForEvent: (NSEvent*) event;
@end

/* Notifications */
extern NSString *TreeMapViewItemTouchedNotification;		//mouse hovered over treemap cell (no selection)
extern NSString *TreeMapViewSelectionDidChangedNotification;
extern NSString *TreeMapViewSelectionIsChangingNotification; //not yet implemented
extern NSString *TMVTouchedItem;	//key for touched item in userInfo of a TreeMapViewItemTouchedNotification

@interface NSObject(TreeMapViewNotifications)
- (void)treeMapViewSelectionDidChange: (NSNotification*) notification;
- (void)treeMapViewSelectionIsChanging: (NSNotification*) notification; //not yet implemented
- (void)treeMapViewItemTouched: (NSNotification*) notification;
@end

