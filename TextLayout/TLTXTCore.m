//
//  TLTXTCore.m
//  TextLayout
//
//  Created by guohy on 2022/10/20.
//  Copyright © 2022 ghy. All rights reserved.
//

#define kTLTXTPerformanceLog 0

#define GetTimeDeltaValue(a) [[NSDate date] timeIntervalSince1970] - [(a) timeIntervalSince1970]

#import "TLTXTCore.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

#import "TLTXTWorker.h"
#import "FileWrapper.h"
#import "TLTXTUtil.h"

#import "TLTXTCachePage.h"
#import "TLTXTPageHelper.h"

@interface TLTXTCore()

@property(nonatomic)TLAttributedString  *attributedString;
@property(nonatomic)CGSize              pageSize;
@property(nonatomic)TLTXTWorker         worker;

@property(nonatomic)dispatch_queue_t    bitmapQueue;//bitmap绘制专用
@property(nonatomic)dispatch_queue_t    imageQueue;//UIImage创建专用

@property(nonatomic)NSInteger           pageNum;//页码翻页时的判断使用 最后一次被请求的页码
@property(nonatomic)NSMutableArray      *cachedArray;//被缓存数组(每个元素包含有这些字段：页码、图片、图片中每个字位置信息)

/**
 *以下两个属性 内容的绘制和生成UIImage都是异步的，翻页时确保上一个操作完成了
 */
@property(nonatomic)dispatch_semaphore_t    nextPageSemaphore;
@property(nonatomic)dispatch_semaphore_t    previousPageSemaphore;
@end

static void rangeAttributesFunc(TLTXTWorker worker,
                                TLRange range,
                                TLRangeArray *rArray,
                                TLTXTAttributesArray *aArray)
{
    TLTXTCore *txtCore = (__bridge TLTXTCore *)(txt_worker_get_context(worker));
    [TLTXTPageHelper checkRangeAttributes:txtCore.attributedString range:range rArray:rArray aArray:aArray];
}

static TLTXTAttributes defaultAttributesFunc(TLTXTWorker worker)
{
    TLTXTCore *txtCore = (__bridge TLTXTCore *)(txt_worker_get_context(worker));
    return [TLTXTPageHelper checkDefaultAttributes:txtCore.attributedString];
}

@implementation TLTXTCore

- (void)dealloc
{
#ifdef DEBUG
    NSLog(@"%@ dealloc", self);
#endif
    txt_worker_destroy(&_worker);
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bitmapQueue = dispatch_queue_create("TextLayout.bitmap", DISPATCH_QUEUE_SERIAL);
        _imageQueue = dispatch_queue_create("TextLayout.image", DISPATCH_QUEUE_SERIAL);
        _cachedArray = [NSMutableArray array];
        _pageNum = -1;
    }
    return self;
}

- (void)resetAttributedString:(TLAttributedString *)aString pageSize:(CGSize)size
{
    if (!aString) {
        return;
    } else if (CGSizeEqualToSize(size, CGSizeZero)) {
        return;
    }
    
    self.attributedString = aString;
    self.pageSize = size;
    
    if (_worker) {
        txt_worker_destroy(&_worker);
        _worker = NULL;
    }
    
    //TODO: 第二个参数不是const的需要改一下
    txt_worker_create(&_worker, [[aString string] UTF8String], size.width, size.height);
    txt_worker_set_context(_worker, (__bridge void *)(self));
    txt_worker_set_range_attributes_callback(_worker, rangeAttributesFunc);
    txt_worker_set_default_attributes_callback(_worker, defaultAttributesFunc);
    
    self.pageNum = -1;
    [self firstTimeDraw:YES startPage:0];
}

- (void)resetAttributedString:(TLAttributedString *)aString
                     pageSize:(CGSize)size
                  cursorArray:(NSArray<NSNumber *> *)cursorArray
                    startPage:(NSInteger)pageNum
{
    if (!aString) {
        return;
    } else if (CGSizeEqualToSize(size, CGSizeZero)) {
        return;
    }
    
    self.attributedString = aString;
    self.pageSize = size;
    
    if (_worker) {
        txt_worker_destroy(&_worker);
        _worker = NULL;
    }
    
    txt_worker_create(&_worker, [[aString string] UTF8String], size.width, size.height);
    txt_worker_set_context(_worker, (__bridge void *)(self));
    txt_worker_set_range_attributes_callback(_worker, rangeAttributesFunc);
    txt_worker_set_default_attributes_callback(_worker, defaultAttributesFunc);
    if (cursorArray.count) {
        for (NSNumber *number in cursorArray) {
            txt_worker_page_cursor_array_prefill(_worker, [number integerValue]);
        }
        txt_worker_total_page_prefill(_worker, cursorArray.count);
    }
    
    self.pageNum = -1;
    [self firstTimeDraw:NO startPage:pageNum];
}

- (void)firstTimeDraw:(BOOL)needsPaging startPage:(NSInteger)pageNum
{
    dispatch_async(self.bitmapQueue, ^{
        if (needsPaging) {
#if kTLTXTPerformanceLog
            NSDate *pagingDate = [NSDate date];
#endif
            txt_worker_data_paging(&self->_worker);
#if kTLTXTPerformanceLog
            NSLog(@"%s paging using time:%@", __func__, @(GetTimeDeltaValue(pagingDate) ));
#endif
        }
        //调用三次对应绘制3页
        size_t total_page = txt_worker_total_page(&self->_worker);
        NSInteger loopCount = 3;
        NSInteger startPageNum = pageNum;
        if (total_page - startPageNum < loopCount) {
            //如果接近结尾
            
            if (total_page > loopCount) {
                //如果页数较多
                startPageNum = total_page - loopCount;
            } else {
                //如果页数较少 从头开始有多少页执行多少次
                startPageNum = 0;
                loopCount = total_page;
            }
        }
        for (NSInteger i=startPageNum; i<startPageNum+loopCount; i++) {
            TLTXTRowRectArray row_rect_array = NULL;
            uint8_t *bitmap = txt_worker_bitmap_one_page(&self->_worker, i, &row_rect_array);
            if (bitmap != NULL) {
                
                dispatch_async(self.imageQueue, ^{
                    UIImage *image = [[self class] imageWith:bitmap width:self.pageSize.width height:self.pageSize.height scale:1];
                    TLTXTCachePage *cachePage = [[TLTXTCachePage alloc] init];
                    cachePage.image = image;
                    cachePage.pageNum = i;
                    cachePage.rowRectArray = row_rect_array;
                    cachePage.cursor = txt_worker_page_cursor_array_get(self.worker, i);
                    cachePage.beforeCursor = i>0 ? txt_worker_page_cursor_array_get(self.worker, i-1) : -1;
                    [self.cachedArray addObject:cachePage];
                    NSInteger arrayCount = self.cachedArray.count;
                    
                    if (arrayCount == loopCount && self.drawDelegate) {
                        self.pageNum = 0;
                        [self.drawDelegate firstPageEnd];
                    }
                });
                
            }
        }
    });
}

- (UIImage *)toPreviousPageOnce
{
    [self toPreviousPage];
    TLTXTCachePage *cachePage = self.cachedArray.firstObject;
    return cachePage.image;
}

- (UIImage *)toNextPageOnce
{
    [self toNextPage];
    TLTXTCachePage *cachePage = self.cachedArray.lastObject;
    return cachePage.image;
}

- (NSArray<NSValue *> *_Nullable)paragraphStartEnd:(NSInteger)page point:(CGPoint)point
{
    TLTXTCachePage *desPage;
    for (NSInteger i=0; i<self.cachedArray.count; i++) {
        TLTXTCachePage *oncePage = self.cachedArray[i];
        if (oncePage.pageNum == page) {
            desPage = oncePage;
            break;
        }
    }
    
    if (desPage){
        CGFloat scale = [UIScreen mainScreen].scale;
        point.x = scale * point.x;
        point.y = scale * point.y;

        NSInteger pStartIndex = -1;
        NSInteger pEndIndex = -1;
        NSInteger newLineIndex = -1;
        NSMutableArray *array = [[NSMutableArray alloc] init];
        
        NSInteger baseIndex = desPage.beforeCursor;
        if (baseIndex == -1) {
            baseIndex = 0;
        }
        
        for (NSInteger i=0; i<desPage.rowRectArray->count; i++) {
            TLTXTRectArray data = desPage.rowRectArray->data[i];
            if (data->count > 0) {
                for (NSInteger j=0; j<data->count; j++) {
                    struct TLTXTRect_ rect = data->data[j];
                    
                    if (pStartIndex == -1) {
                        if (rect.codepoint_index == 0 || (i==0 && j==0)) {
                            //如果第一个字符是开头
                            [array removeAllObjects];
                            newLineIndex = rect.codepoint_index;
                        } else if (rect.codepoint_index>0) {
                            NSInteger rectBeforeIndex = rect.codepoint_index - 1;
                            NSString *oneString = [self.attributedString.string substringWithRange:NSMakeRange(rectBeforeIndex, 1)];
                            if ([oneString isEqualToString: @"\n"]) {
                                //如果上一个字符是换行符
                                [array removeAllObjects];
                                newLineIndex = rect.codepoint_index;
                            }
                        }
                    } else if (pEndIndex == -1) {
                        if (i == desPage.rowRectArray->count-1 && j == data->count) {
                            //本页最后一个字
                            pEndIndex = rect.codepoint_index;
                            break;
                        } else {
                            NSInteger rectAfterIndex = rect.codepoint_index + 1;
                            NSString *oneString = [self.attributedString.string substringWithRange:NSMakeRange(rectAfterIndex, 1)];
                            if ([oneString isEqualToString: @"\n"]) {
                                //下一个字是换行
                                pEndIndex = rect.codepoint_index;
                                break;
                            }
                        }
                    }
                    
                    CGRect onceRect = CGRectMake(rect.x, rect.y, rect.xx - rect.x, rect.yy - rect.y);
                    if (CGRectContainsPoint(onceRect, point) && pStartIndex == -1) {
                        pStartIndex = newLineIndex;
                    }
                    
                    [array addObject:[NSValue valueWithCGRect:onceRect]];
                }
            }
            
            if (pStartIndex >=0 && pEndIndex >=0) {
                break;
            }
        }
        
        if (pStartIndex >=0 && pEndIndex >=0) {
            //找了具体某一段
        } else if (pStartIndex >=0) {
            //只有开始没有结束
        } else if (pEndIndex >=0) {
            //只有结束没有开始
        } else {
            //一整屏的文字没有换行
        }
        
        NSArray *tempArray = [NSArray arrayWithArray:array];
        [array removeAllObjects];
        for (NSValue *rectValue in tempArray) {
            CGRect onceRect = [rectValue CGRectValue];
            onceRect.origin.x = onceRect.origin.x/scale;
            onceRect.origin.y = onceRect.origin.y/scale;
            onceRect.size.width = onceRect.size.width/scale;
            onceRect.size.height = onceRect.size.height/scale;
            [array addObject:[NSValue valueWithCGRect:onceRect]];
        }
        
        if (pStartIndex >=0 && pEndIndex >=0) {
            //开始位置+1不包含第一个换行
            NSInteger startIndex = pStartIndex;
            NSInteger length = pEndIndex - pStartIndex;
#ifdef DEBUG
            NSLog(@"page:%@ 被选中的文字：%@", @(page),[self.attributedString.string substringWithRange:NSMakeRange(startIndex, length)]);
#endif
        }
        if (pStartIndex >=0) {
            return array;
        }
    }
    return nil;
}

- (UIImage *)imageWithPageNum:(NSInteger)pageNum
{
    if (pageNum >=0 && pageNum < [self totalPage] && self.cachedArray.count) {
        NSInteger index = -1;
        for (NSInteger i=0; i<self.cachedArray.count; i++) {
            TLTXTCachePage *oncePage = self.cachedArray[i];
            if (oncePage.pageNum == pageNum) {
                index = i;
            }
        }
        bool pageNumIsEqual = true;
        if (self.pageNum != pageNum){
            self.pageNum = pageNum;
            pageNumIsEqual = false;
        }
        if (index == 0) {
            if (pageNum == 0) {
                TLTXTCachePage *cachePage = self.cachedArray.firstObject;
                return cachePage.image;
            } else {
                if (!pageNumIsEqual){
                    return [self toPreviousPageOnce];
                }
            }
        } else if (index == self.cachedArray.count -1) {
            if (pageNum == [self totalPage]-1) {
                TLTXTCachePage *cachePage = self.cachedArray.lastObject;
                return cachePage.image;
            } else {
                if (!pageNumIsEqual){
                    return [self toNextPageOnce];
                }
            }
        } else {
            TLTXTCachePage *cachePage = nil;
            if (self.cachedArray.count > 1) {
                cachePage = self.cachedArray[1];
            }
            return cachePage.image;
        }
    }
    return nil;
}

- (UIImage *_Nullable)onlyCachedImageWithPageNum:(NSInteger)pageNum
{
    if (pageNum >=0 && pageNum < [self totalPage] && self.cachedArray.count) {
        TLTXTCachePage *cachePage = nil;
        for (NSInteger i=0; i<self.cachedArray.count; i++) {
            TLTXTCachePage *oncePage = self.cachedArray[i];
            if (oncePage.pageNum == pageNum) {
                cachePage = oncePage;
            }
        }
        return cachePage.image;
    }
    return nil;
}

- (void)toCacheWhenMoveTo:(NSInteger)pageNum
{
    if (pageNum >=0 && pageNum < [self totalPage] && self.cachedArray.count) {
        NSInteger index = -1;
        for (NSInteger i=0; i<self.cachedArray.count; i++) {
            TLTXTCachePage *oncePage = self.cachedArray[i];
            if (oncePage.pageNum == pageNum) {
                index = i;
            }
        }
        bool pageNumIsEqual = true;
        if (self.pageNum != pageNum){
            self.pageNum = pageNum;
            pageNumIsEqual = false;
        }
        if (index == 0) {
            if (pageNum == 0) {
            } else {
                if (!pageNumIsEqual){
                    [self toPreviousPage];
                }
            }
        } else if (index == self.cachedArray.count -1) {
            if (pageNum == [self totalPage]-1) {
            } else {
                if (!pageNumIsEqual){
                    [self toNextPage];
                }
            }
        }
    }
}

- (NSInteger)totalPage
{
    return txt_worker_total_page(&_worker);
}

+ (NSArray<NSNumber *> *)oncePaging:(TLAttributedString *)aString pageSize:(CGSize)pageSize endPageHeight:(CGFloat*)height
{
    return [TLTXTPageHelper oncePaging:aString pageSize:pageSize endPageHeight:height];
}

#pragma mark- Private methods

- (void)toNextPage
{
    //信号量的赋值视为在主线程
    if (self.nextPageSemaphore) {
        dispatch_semaphore_wait(self.nextPageSemaphore, DISPATCH_TIME_FOREVER);
    }
    if (!(self.pageNum + 1 < [self totalPage])) {
        return;
    }
    NSInteger afterPageNum = self.pageNum+1;
    self.nextPageSemaphore = dispatch_semaphore_create(0);
    
    dispatch_async(self.bitmapQueue, ^{
    
#if kTLTXTPerformanceLog
    NSDate *date = [NSDate date];
#endif

#if kTLTXTPerformanceLog
    NSDate *bitmapStartDate = [NSDate date];
#endif
    TLTXTRowRectArray row_rect_array = NULL;
    uint8_t *bitmap = txt_worker_bitmap_one_page(&self->_worker,afterPageNum, &row_rect_array);
#if kTLTXTPerformanceLog
    NSLog(@"%s bitmap using time:%@", __func__, @(GetTimeDeltaValue(bitmapStartDate) ));
#endif
    if (bitmap != NULL) {
        
        dispatch_async(self.imageQueue, ^{
#if kTLTXTPerformanceLog
            NSDate *imageStartDate = [NSDate date];
#endif
            UIImage *image = [[self class] imageWith:bitmap width:self.pageSize.width height:self.pageSize.height scale:1];
            TLTXTCachePage *cachePage = [[TLTXTCachePage alloc] init];
            cachePage.pageNum = afterPageNum;
            cachePage.image = image;
            cachePage.rowRectArray = row_rect_array;
            cachePage.cursor = txt_worker_page_cursor_array_get(self.worker, afterPageNum);
            cachePage.beforeCursor = afterPageNum>0 ? txt_worker_page_cursor_array_get(self.worker, afterPageNum-1) : -1;
            NSMutableArray *array = [NSMutableArray arrayWithArray:self.cachedArray];
            [array removeObjectAtIndex:0];
            [array addObject:cachePage];
            
            self.cachedArray = array;
#if kTLTXTPerformanceLog
            NSLog(@"%s image create using time:%@", __func__, @(GetTimeDeltaValue(imageStartDate) ));
#endif
            
#if kTLTXTPerformanceLog
    NSLog(@"%s using time:%@", __func__, @(GetTimeDeltaValue(date) ));
#endif
            dispatch_semaphore_signal(self.nextPageSemaphore);
            if (self.drawDelegate) {
                [self.drawDelegate didDrawPageEnd:afterPageNum];
            }
        });
            
    } else {
        dispatch_semaphore_signal(self.nextPageSemaphore);
    }
    });
}

- (void)toPreviousPage
{
    //信号量的赋值视为在主线程
    if (self.previousPageSemaphore) {
        dispatch_semaphore_wait(self.previousPageSemaphore, DISPATCH_TIME_FOREVER);
    }
    if (!(self.pageNum > 0)) {
        return;
    }
    NSInteger afterPageNum = self.pageNum-1;
    self.previousPageSemaphore = dispatch_semaphore_create(0);
    dispatch_async(self.bitmapQueue, ^{
    
#if kTLTXTPerformanceLog
    NSDate *date = [NSDate date];
#endif

#if kTLTXTPerformanceLog
    NSDate *bitmapStartDate = [NSDate date];
#endif
    TLTXTRowRectArray row_rect_array = NULL;
    uint8_t *bitmap = txt_worker_bitmap_one_page(&self->_worker,afterPageNum, &row_rect_array);
#if kTLTXTPerformanceLog
    NSLog(@"%s bitmap using time:%@", __func__, @(GetTimeDeltaValue(bitmapStartDate) ));
#endif
    if (bitmap != NULL) {
        
        dispatch_async(self.imageQueue, ^{
#if kTLTXTPerformanceLog
            NSDate *imageStartDate = [NSDate date];
#endif
            UIImage *image = [[self class] imageWith:bitmap width:self.pageSize.width height:self.pageSize.height scale:1];
            TLTXTCachePage *cachePage = [[TLTXTCachePage alloc] init];
            cachePage.pageNum = afterPageNum;
            cachePage.image = image;
            cachePage.rowRectArray = row_rect_array;
            cachePage.cursor = txt_worker_page_cursor_array_get(self.worker, afterPageNum);
            cachePage.beforeCursor = afterPageNum>0 ? txt_worker_page_cursor_array_get(self.worker, afterPageNum-1) : -1;
            NSMutableArray *array = [NSMutableArray arrayWithArray:self.cachedArray];
            [array removeObjectAtIndex:2];
            [array insertObject:cachePage atIndex:0];
            self.cachedArray = array;
#if kTLTXTPerformanceLog
            NSLog(@"%s image create using time:%@", __func__, @(GetTimeDeltaValue(imageStartDate) ));
#endif
            
#if kTLTXTPerformanceLog
    NSLog(@"%s using time:%@", __func__, @(GetTimeDeltaValue(date) ));
#endif
            dispatch_semaphore_signal(self.previousPageSemaphore);
            if (self.drawDelegate) {
                [self.drawDelegate didDrawPageEnd:afterPageNum];
            }
        });
            
    } else {
        dispatch_semaphore_signal(self.previousPageSemaphore);
    }
    });
}

+ (UIImage *)imageWith:(uint8_t *)bytes width:(CGFloat)bWidth height:(CGFloat)bHeight scale:(CGFloat)scale
{
    NSInteger componentsCount = 4;
    CGFloat width = bWidth;
    CGFloat height = bHeight;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGContextRef contextRef = CGBitmapContextCreate(bytes,                 // Pointer to backing data
                                                    width,                       // Width of bitmap
                                                    height,                       // Height of bitmap
                                                    8,                          // Bits per component
                                                    width*componentsCount,              // Bytes per row
                                                    colorSpace,                 // Colorspace
                                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big); // Bitmap info flags
    CGImageRef mainViewContentBitmapContext = CGBitmapContextCreateImage(contextRef);
    CGContextRelease(contextRef);
    free(bytes);
    UIImage *result = [UIImage imageWithCGImage:mainViewContentBitmapContext scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(mainViewContentBitmapContext);
    return result;
}

+ (NSString *)convertCodePoint:(uint32_t)code_point
{
    uint8_t one = (code_point>>24)&0XFF;//按当前标准 这个字节忽略；只考虑后三个字节
    uint8_t two = (code_point>>16)&0XFF;
    uint8_t three = (code_point>>8)&0XFF;
    uint8_t four = code_point&0XFF;
    
    NSString *result = nil;
    if (one == 0 && two == 0) {
        if (three != 0) {
            if (three >= 8) {
                //三字节
                Byte byteData[] = {0xe0+((three>>4)&0xf), 0x80+ ((three<<2)&0x3c) + ((four>>6)&0x3), 0x80+(four&0x3f)};
                NSData *data = [NSData dataWithBytes:byteData length:sizeof(byteData)];
                result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            } else {
                //两字节
                Byte byteData[] = {0xc0+((three>>3)&0x1f), 0x80+(four&0x3f)};
                result = [[NSString alloc] initWithData:[NSData dataWithBytes:byteData length:sizeof(byteData)] encoding:NSUTF8StringEncoding];
            }
        } else {
            Byte byteData[] = {four};
            result = [[NSString alloc] initWithData:[NSData dataWithBytes:byteData length:sizeof(byteData)] encoding:NSUTF8StringEncoding];
        }
    } else {
        //四字节
        Byte byteData[] = {0xf0 + ((two>>2)&0x7), 0x80+ ((three>>4)&0xf) + ((two<<4)&0x30), 0x80+ ((three<<2)&0x3c) + ((four>>6)&0x3), 0x80+(four&0x3f)};
        result = [[NSString alloc] initWithData:[NSData dataWithBytes:byteData length:sizeof(byteData)] encoding:NSUTF8StringEncoding];
    }
    NSLog(@"点选结果是:%@", result);
    NSLog(@"%x %x %x %x code_point:%x", one, two, three, four, code_point);
    return result;
}

+ (NSData *)dataWithCodePoint:(uint32_t)code_point
{
    uint8_t one = (code_point>>24)&0XFF;
    uint8_t two = (code_point>>16)&0XFF;
    uint8_t three = (code_point>>8)&0XFF;
    uint8_t four = code_point&0XFF;
    
    NSData *data;
    if (one == 0 && two == 0) {
        if (three != 0) {
            if (three >= 8) {
                //三字节
                Byte byteData[] = {0xe0+((three>>4)&0xf), 0x80+ ((three<<2)&0x3c) + ((four>>6)&0x3), 0x80+(four&0x3f)};
                data = [NSData dataWithBytes:byteData length:sizeof(byteData)];
            } else {
                //两字节
                Byte byteData[] = {0xc0+((three>>3)&0x1f), 0x80+(four&0x3f)};
                data = [NSData dataWithBytes:byteData length:sizeof(byteData)];
            }
        } else {
            Byte byteData[] = {four};
            data = [NSData dataWithBytes:byteData length:sizeof(byteData)];
        }
    } else {
        //四字节
        Byte byteData[] = {0xf0 + ((two>>2)&0x7), 0x80+ ((three>>4)&0xf) + ((two<<4)&0x30), 0x80+ ((three<<2)&0x3c) + ((four>>6)&0x3), 0x80+(four&0x3f)};
        data = [NSData dataWithBytes:byteData length:sizeof(byteData)];
    }
    return data;
}

+ (NSString *)convertCodePoints:(uint32_t*)code_points count:(size_t)count
{
    NSMutableData *result = [NSMutableData data];
    for (size_t i=0; i<count; i++) {
        NSData *data = [self dataWithCodePoint:code_points[i]];
        [result appendData:data];
    }
    NSString *string = [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
    return string;
}

@end
