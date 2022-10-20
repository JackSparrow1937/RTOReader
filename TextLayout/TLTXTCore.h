//
//  TLTXTCore.h
//  TextLayout
//
//  Created by guohy on 2022/10/20.
//  Copyright © 2022 ghy. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TLTXTCoreDrawDelegate <NSObject>

/**
 *第一页绘制完成
 */
- (void)firstPageEnd;

@end

/**
 *TXT相关功能的核心，便于iOS使用。
 */
@interface TLTXTCore : NSObject

@property(nonatomic,weak)id<TLTXTCoreDrawDelegate>  drawDelegate;

/**
 *重置文件路径和页面大小
 */
- (void)resetFilePath:(NSString *)path pageSize:(CGSize)size;

/**
 *获取当前页内容
 */
- (UIImage *)currentPageImage;

/**
 *获取上一页的内容，并继续向上一页进一步
 */
- (UIImage *)toPreviousPageOnce;

/**
 *获取下一页的内容，并继续向下一页进一步
 */
- (UIImage *)toNextPageOnce;

@end

NS_ASSUME_NONNULL_END
