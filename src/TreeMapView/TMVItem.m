//
//  TMVItem.m
//  DiskAccountant
//
//  Created by Tjark Derlien on Tue Sep 30 2003.
//  Copyright (c) 2003 Tjark Derlien. All rights reserved.
//

#import "TMVItem.h"
#import "TreeMapView.h"
#import "NSView-BackingCoordsHelpers.h"

#define  CUSHION_SCALE_FACTOR	 0.9f

static NSColor* _parentGridColor;
static NSColor* _leafGridColor;
static NSColor* _highlightGridColor;
static NSColor* _nameColor;

static NSMutableDictionary *_gridTextAttributes;
static NSMutableDictionary *_cushionTextAttributes;

typedef struct { TMVCushionRenderer **renderers; NSUInteger count, capacity; } TMVLeafList;

//============================ interface TMVItem( Private ) =============================================

@interface TMVItem( Private )

- (void) collectLeaves: (TMVLeafList*) leaves parentCushion: (TMVCushionRenderer*) parentCushion cushionHeightFactor: (float) heightFactor;

- (void) layoutChilds;
- (void) setHidden;
- (NSUInteger) arrangeChildsOnRows: (double*) rows
                      childsPerRow: (NSUInteger*) childsPerRow
                       childWidths: (double*) childWidths
                           weights: (const double*) weights
                        childCount: (NSUInteger) childCount
                      rowsAreHoriz: (BOOL*) horizontal;
- (double) calculateRow: (NSUInteger) startChildIndex
               rowWidth: (double) rowWidth
            childsUsed : (NSUInteger*) childsUsed
            childWidths: (double*) childWidths
                weights: (const double*) weights
             childCount: (NSUInteger) childCount;
@end

//============================ implementation TMVItem =============================================

@implementation TMVItem

+ (void) initialize
{
    if ( _parentGridColor == nil )
        _parentGridColor = [[NSColor textColor] retain];
    if ( _leafGridColor == nil )
        _leafGridColor = [[NSColor disabledControlTextColor] retain];
    if ( _highlightGridColor == nil )
        _highlightGridColor = [[NSColor yellowColor] retain];
    if ( _nameColor == nil )
        _nameColor = [[NSColor disabledControlTextColor] retain];
	
    if ( _gridTextAttributes == nil )
        _gridTextAttributes = [[NSMutableDictionary alloc] init];
    if ( _cushionTextAttributes == nil )
        _cushionTextAttributes = [[NSMutableDictionary alloc] init];
}

- (id) initWithDataSource: (id) dataSource delegate: (id) delegate renderedItem: (id) item treeMapView: (id) view
{
    self = [super init];
    
    _item = item;
    _dataSource = dataSource;
    _delegate = delegate;
    _view = view;
	_rect = NSZeroRect;

    _cushionRenderer = [[TMVCushionRenderer alloc] init];

    // Child renderers are created when they get laid out, see -layoutChilds.
    return self;
}

- (void) dealloc
{
    [_childRenderers release];
    [_cushionRenderer release];

    [super dealloc];
}

- (void) refreshWithItem: (id) item
{
    _item = item;
	_rect = NSZeroRect;
	_hasCachedIsLeaf = NO;
	_hasCachedWeight = NO;
	
	[_cushionRenderer setRect: NSZeroRect];
	
	[_childRenderers release];
	_childRenderers = nil;
}

- (void) setCushionColor: (NSColor*) color
{
    [_cushionRenderer setColor: color];
}

- (void) calcLayout: (NSRect) rect
{
    // Renderers work in integral backing-store coordinates. Some display
    // setups (virtualized / paravirtual GPUs, fractional-scale or split-view
    // layouts) hand the root a fractional backing rect, which trips the
    // integral-rect assertions below and crashes during -drawRect: in debug
    // builds. Snap to integral up front so every layout rect is well-formed.
    rect = NSIntegralRect( rect );

    if ( NSEqualRects( _rect, rect ) )
		return;

    //NSAssert( NSWidth(_rect) == roundf( NSWidth(_rect) ), @"rect width is not an integral value");
    //NSAssert( NSHeight(_rect) == roundf( NSHeight(_rect) ), @"rect height is not an integral value");
    NSAssert( ( rect.origin.x - (CGFloat)(int)rect.origin.x ) == 0.0 , @"rect.origin.x is not an integral value");
    NSAssert( ( rect.origin.y - (CGFloat)(int)rect.origin.y ) == 0.0 , @"rect.origin.y is not an integral value");
    NSAssert( ( rect.size.width - (CGFloat)(int)rect.size.width ) == 0.0 , @"rect.size.width is not an integral value");
    NSAssert( ( rect.size.height - (CGFloat)(int)rect.size.height ) == 0.0 , @"height is not an integral value");

    _rect = rect;
    [_cushionRenderer setRect: rect];
    
    //if the rect is too small, we do nothing
    {
        const CGFloat scale = [_view backingScaleForLayout];
        if ( NSHeight( _rect ) / scale < 1 || NSWidth( _rect ) / scale < 1 )
            return;
    }
    
    if ( ![self isLeaf] )
        [self layoutChilds];
}

- (void ) drawGrid
{
    if ( [self isLeaf] )
    {
        NSRect rectPoints = [_view convertRectFromBackingRespectingFlipped:_rect];
        
        [_leafGridColor set];

        NSFrameRectWithWidthUsingOperation(rectPoints, 1, NSCompositingOperationCopy );

/*        if ( NSWidth(_rect) > 60 && NSHeight(_rect) > 20 )
        {
            //            [_gridTextAttributes setObject: [NSFont fontWithName:@"Times" size: 24]
            //                        forKey:NSFontAttributeName];
            [_gridTextAttributes setObject: _leafGridColor forKey:NSForegroundColorAttributeName];
            [[_item displayName] drawInRect: rectPoints withAttributes: _gridTextAttributes];
        }
        */
    }
    else
    {
        NSEnumerator *childEnum = [_childRenderers objectEnumerator];
        TMVItem *childRenderer;
        while ( ( childRenderer = [childEnum nextObject] ) != nil )
        {
            [childRenderer drawGrid];
        }
    }
}

- (void) drawHighlightFrame
{
    NSRect rectPoints = [_view convertRectFromBackingRespectingFlipped: _rect];
    
    //if the rect is too small, we do nothing
    if ( NSHeight( rectPoints) < 1 || NSWidth( rectPoints ) < 1 )
        return;
    
    [_highlightGridColor set];
	
	float oldLineWidth = [NSBezierPath defaultLineWidth];
	[NSBezierPath setDefaultLineWidth: 2];
	
    [NSBezierPath strokeRect: rectPoints];
	
	[NSBezierPath setDefaultLineWidth: oldLineWidth];
}

- (void) drawCushionInBitmap: (NSBitmapImageRep*) bitmap
{
    // First, in draw order: work out each cushion's surface and ask for its color,
    // which hands out the colors of the file kinds in the order they get seen.
    TMVLeafList leaves = { NULL, 0, 0 };
    [self collectLeaves: &leaves parentCushion: nil cushionHeightFactor: 0.5f];

    if ( leaves.count == 0 || [_view backgroundRenderCancelled] )
    {
        free( leaves.renderers );
        return;
    }

    // Then the pixels: every leaf covers its own part of the bitmap, so they can run side by side.
    unsigned char *pixels = [bitmap bitmapData];
    const NSInteger bytesPerRow = [bitmap bytesPerRow];
    TMVCushionRenderer **renderers = leaves.renderers;
    const NSUInteger leafCount = leaves.count;
    const NSUInteger batchSize = 64;
    const NSUInteger batchCount = ( leafCount + batchSize - 1 ) / batchSize;

    dispatch_apply( batchCount, dispatch_get_global_queue( QOS_CLASS_USER_INITIATED, 0 ), ^( size_t batch ) {
        @autoreleasepool
        {
            const NSUInteger end = MIN( ( batch + 1 ) * batchSize, leafCount );
            for ( NSUInteger i = batch * batchSize; i < end; i++ )
                [renderers[i] renderCushionInPixels: pixels bytesPerRow: bytesPerRow];
        }
    });

    free( leaves.renderers );
}

- (BOOL) isLeaf
{
    if ( !_hasCachedIsLeaf )
    {
        _cachedIsLeaf = ![_dataSource treeMapView: _view isNode: _item];
        _hasCachedIsLeaf = YES;
    }
    return _cachedIsLeaf;
}

- (id) item
{
    return _item;
}

- (unsigned long long) weight
{
    if ( !_hasCachedWeight )
    {
        _cachedWeight = [_dataSource treeMapView: _view weightByItem: _item];
        _hasCachedWeight = YES;
    }
    return _cachedWeight;
}

- (NSRect) rect
{
    return _rect;
}

- (NSEnumerator *) childEnumerator
{

    return [_childRenderers objectEnumerator];
}

- (TMVItem*) childAtIndex: (unsigned) childIndex
{
    return [_childRenderers objectAtIndex: childIndex];
}

- (NSUInteger) childCount
{
    return [_childRenderers count];
}

- (TMVItem *) hitTest: (NSPoint) aPoint
{
    if ( !NSPointInRect( aPoint, _rect ) )
        return nil;
    
    if ( [self isLeaf] )
    {
        return self;
    }
    else
    {
        NSEnumerator *childEnum = [_childRenderers objectEnumerator];
        TMVItem *childRenderer;
        while ( ( childRenderer = [childEnum nextObject] ) != nil )
        {
            TMVItem *hittedChildRenderer = [childRenderer hitTest: aPoint];            
            if ( hittedChildRenderer != nil )
                return hittedChildRenderer;
        }
        return nil;
    }
}

@end

//============================ implementation TMVItem( Private ) =============================================

@implementation TMVItem( Private )

- (void) collectLeaves: (TMVLeafList*) leaves parentCushion: (TMVCushionRenderer*) parentCushion cushionHeightFactor: (float) heightFactor
{
    if ( [_view backgroundRenderCancelled] )
        return;

    //if the rect is too small, we do nothing
    {
        const CGFloat scale = [_view backingScaleForLayout];
        if ( NSHeight( _rect ) / scale < 1 || NSWidth( _rect ) / scale < 1 )
            return;
    }

    if ( parentCushion != NULL )
    {
        [_cushionRenderer setSurface: [parentCushion surface]];
        [_cushionRenderer addRidgeByHeightFactor: heightFactor];
    }

    if ( [self isLeaf] )
    {
        if ( _delegate != nil && [_delegate respondsToSelector: @selector(treeMapView: willDisplayItem: withRenderer:)] )
            [_delegate treeMapView: _view willDisplayItem: _item withRenderer: self];

        if ( leaves->count == leaves->capacity )
        {
            leaves->capacity = leaves->capacity != 0 ? leaves->capacity * 2 : 1024;
            leaves->renderers = realloc( leaves->renderers, leaves->capacity * sizeof(TMVCushionRenderer*) );
        }
        leaves->renderers[leaves->count++] = _cushionRenderer;
    }
    else
    {
        for ( TMVItem *child in _childRenderers )
            [child collectLeaves: leaves parentCushion: _cushionRenderer cushionHeightFactor: (heightFactor * CUSHION_SCALE_FACTOR)];
    }
}

- (void) layoutChilds
{
    if ( [_view backgroundRenderCancelled] )
        return;

    const NSUInteger childCount = [_dataSource treeMapView: _view numberOfChildrenOfItem: _item];

    NSArray *oldRenderers = _childRenderers;
    _childRenderers = [[NSMutableArray alloc] init];

    if ( childCount == 0 )
    {
        [oldRenderers release];
        return;
    }

    id *items = malloc( childCount * sizeof(id) );
    double *weights = malloc( childCount * sizeof(double) );
    double *rows = malloc( childCount * sizeof(double) );          //fraction of total height for each row
    NSUInteger *childsPerRow = malloc( childCount * sizeof(NSUInteger) );
    double *childWidths = malloc( childCount * sizeof(double) );   //fraction of total width for each child

    for ( NSUInteger i = 0; i < childCount; i++ )
    {
        items[i] = [_dataSource treeMapView: _view child: i ofItem: _item];
        NSAssert( items[i] != nil, @"data source returned nil as child item" );
        weights[i] = [_dataSource treeMapView: _view weightByItem: items[i]];
    }

    BOOL horizontalRows;
    NSUInteger rowCount = [self arrangeChildsOnRows: rows
                                       childsPerRow: childsPerRow
                                        childWidths: childWidths
                                            weights: weights
                                         childCount: childCount
                                       rowsAreHoriz: &horizontalRows];

    const int parentWidth = (int) /*roundf*/( horizontalRows ? NSWidth(_rect) : NSHeight(_rect) );
    const int parentHeight = (int) /*roundf*/( horizontalRows ? NSHeight(_rect) : NSWidth(_rect) );

    const int parentBottom = (int) /*roundf*/( horizontalRows ? NSMaxY(_rect) : NSMaxX(_rect) );
    const int parentRight = (int) /*roundf*/( horizontalRows ? NSMaxX(_rect) : NSMaxY(_rect) );
    const int parentLeft = (int) /*roundf*/( horizontalRows ? NSMinX(_rect) : NSMinY(_rect) );

    const CGFloat scale = [_view backingScaleForLayout];
    const NSUInteger oldCount = [oldRenderers count];
    NSUInteger oldIndex = 0;
    NSUInteger childIndex = 0;

    int top = horizontalRows ? NSMinY(_rect) : NSMinX(_rect);

    for ( NSUInteger row = 0; row < rowCount; row++ )
    {
        int bottom = top + roundf( rows[row] * parentHeight );
        //if this is the last row, make sure it's bottom is the same as our bottom (get rid of rounding errors)
        if ( bottom > parentBottom || row == rowCount - 1 )
            bottom = parentBottom;

        int left = parentLeft;

        for ( NSUInteger column = 0; column < childsPerRow[row]; column++, childIndex++ )
        {
            int right = left + roundf( childWidths[childIndex] * parentWidth );
            //if this is last child in the current row, make sure it's rect ends with our rect
            if ( right > parentRight || column == childsPerRow[row] - 1 )
                right = parentRight;

            NSRect rcChild;
            if (horizontalRows)
            {
                rcChild.origin.x = left;
                rcChild.origin.y = top;
                rcChild.size.width  = right - left;
                rcChild.size.height = bottom - top;
            }
            else
            {
                rcChild.origin.x = top;
                rcChild.origin.y = left;
                rcChild.size.width  = bottom - top;
                rcChild.size.height = right - left;
            }

            TMVItem *reusable = nil;
            if ( oldIndex < oldCount && [[oldRenderers objectAtIndex: oldIndex] item] == items[childIndex] )
                reusable = [oldRenderers objectAtIndex: oldIndex++];

            if ( NSWidth( rcChild ) / scale >= 1 && NSHeight( rcChild ) / scale >= 1 )
            {
                TMVItem *childRenderer = reusable;
                if ( childRenderer == nil )
                    childRenderer = [[[TMVItem alloc] initWithDataSource: _dataSource
                                                                delegate: _delegate
                                                            renderedItem: items[childIndex]
                                                             treeMapView: _view] autorelease];
                [_childRenderers addObject: childRenderer];
                [childRenderer calcLayout: rcChild];
            }
            else
                [reusable setHidden]; //the view may still hold on to it

            left = right;
        }

        top = bottom;
    }

    free( items );
    free( weights );
    free( rows );
    free( childsPerRow );
    free( childWidths );

    [oldRenderers release];
}

- (void) setHidden
{
    _rect = NSZeroRect;
    [_cushionRenderer setRect: NSZeroRect];
}

- (NSUInteger) arrangeChildsOnRows: (double*) rows
                      childsPerRow: (NSUInteger*) childsPerRow
                       childWidths: (double*) childWidths
                           weights: (const double*) weights
                        childCount: (NSUInteger) childCount
                      rowsAreHoriz: (BOOL*) horizontal
{
    if ( [self weight] == 0 )
    {
        rows[0] = 1;
        childsPerRow[0] = childCount;

        for ( NSUInteger i = 0; i < childCount; i++ )
            childWidths[i] = 1.0 / childCount;

        *horizontal = TRUE;
        return 1;
    }

    *horizontal = _rect.size.width >= _rect.size.height;

    double width = 1;
    if ( *horizontal )
    {
        if ( _rect.size.height > 0 )
            width = (double) _rect.size.width / _rect.size.height;
    }
    else
    {
        if ( _rect.size.width > 0 )
            width = (double) _rect.size.height / _rect.size.width;
    }

    NSUInteger rowCount = 0;
    for ( NSUInteger i = 0; i < childCount; )
    {
        NSUInteger childsUsed = 0;
        rows[rowCount] = [self calculateRow: i
                                   rowWidth: width
                                 childsUsed: &childsUsed
                                childWidths: childWidths
                                    weights: weights
                                 childCount: childCount];
        childsPerRow[rowCount++] = childsUsed;

        i += childsUsed;
    }
    return rowCount;
}

- (double) calculateRow: (NSUInteger) startChildIndex
               rowWidth: (double) rowWidth
            childsUsed : (NSUInteger*) childsUsed
            childWidths: (double*) childWidths
                weights: (const double*) weights
             childCount: (NSUInteger) childCount
{
    static const double minProportion = 0.4;
    const double mySize= [self weight];
    NSUInteger i;
    double sizeUsed= 0;
    double rowHeight= 0;

    *childsUsed = 0;

    for  ( i = startChildIndex; i < childCount; i++ )
    {
        double childSize = weights[i];
        if ( childSize == 0)
        {
            NSAssert( i > startChildIndex, @"first child must not have size of 0" );
            break;
        }

        sizeUsed += childSize;
        double virtualRowHeight = sizeUsed / mySize;
        NSAssert( virtualRowHeight > 0 && virtualRowHeight <= 1, @"incorrect calculated parent size ( sum(childs) > parent )" );

        // Rectangle(mySize)    = width * 1.0
        // Rectangle(childSize) = childWidth * virtualRowHeight
        // Rectangle(childSize) = childSize / mySize * width

        double childWidth= childSize / mySize * rowWidth / virtualRowHeight;

        if (childWidth / virtualRowHeight < minProportion)
        {
            NSAssert(i > startChildIndex, @"" ); // because width >= 1 and _minProportion < 1.
                                                 // For the first child we have:
                                                 // childWidth / rowHeight
                                                 // = childSize / mySize * width / rowHeight / rowHeight
                                                 // = childSize * width / sizeUsed / sizeUsed * mySize
                                                 // > childSize * mySize / sizeUsed / sizeUsed
                                                 // > childSize * childSize / childSize / childSize
                                                 // = 1 > _minProportion.
            break;
        }
        rowHeight = virtualRowHeight;
    }
    NSAssert(i > startChildIndex, @"row calculation aborted" );

    // Now i-1 is the last child used
    // and rowHeight is the height of the row.

    // We add the rest of the zero-sized childs
    while ( i < childCount && weights[i] == 0 )
        i++;

    *childsUsed = i - startChildIndex;

	// Rectangle(1.0 * 1.0) = mySize
	double rowSize = mySize * rowHeight;
	
    // Now as we know the rowHeight, we compute the widths of our children.
    for ( i = 0; i < *childsUsed; i++ )
        childWidths[startChildIndex + i] = weights[startChildIndex + i] / rowSize;

    return rowHeight;
}

@end
