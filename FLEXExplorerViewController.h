//
//  FLEXExplorerViewController.h
//  Flipboard
//
//  Created by Ryan Olson on 4/4/14.
//  Copyright (c) 2020 FLEX Team. All rights reserved.
//

#import "FLEXExplorerToolbar.h"

@class FLEXWindow;
@protocol FLEXExplorerViewControllerDelegate;

/// A view controller that manages the FLEX toolbar.
@interface FLEXExplorerViewController : UIViewController

@property (nonatomic, weak) id <FLEXExplorerViewControllerDelegate> delegate;
@property (nonatomic, readonly) BOOL wantsWindowToBecomeKey;

@property (nonatomic, readonly) FLEXExplorerToolbar *explorerToolbar;

- (BOOL)shouldReceiveTouchAtWindowPoint:(CGPoint)pointInWindowCoordinates;

/// @brief Used to present (or dismiss) a modal view controller ("tool"),
/// typically triggered by pressing a button in the toolbar.
///
/// If a tool is already presented, this method simply dismisses it and calls the completion block.
/// If no tool is presented, @code future() @endcode is presented and the completion block is called.
- (void)toggleToolWithViewControllerProvider:(UINavigationController *(^)(void))future
                                  completion:(void (^)(void))completion;

/// @brief Used to present (or dismiss) a modal view controller ("tool"),
/// typically triggered by pressing a button in the toolbar.
///
/// If a tool is already presented, this method dismisses it and presents the given tool.
/// The completion block is called once the tool has been presented.
- (void)presentTool:(UINavigationController *(^)(void))future
         completion:(void (^)(void))completion;

/// @brief 同上，但可以关掉转场动画。
///
/// 从悬浮球恢复会话时窗口刚刚被重新显示，再叠一段 present 动画会先露出下面的面板，
/// 观感上就是"闪一下"，这种场景用 animated:NO 直接到位。
- (void)presentTool:(UINavigationController *(^)(void))future
           animated:(BOOL)animated
         completion:(void (^)(void))completion;

- (void)showAiFlex3PanelForObject:(id)object report:(NSString *)report className:(NSString *)className;

// Keyboard shortcut helpers

- (void)toggleSelectTool;
- (void)toggleMoveTool;
- (void)toggleViewsTool;
- (void)toggleMenuTool;

/// @return YES if the explorer used the key press to perform an action, NO otherwise
- (BOOL)handleDownArrowKeyPressed;
/// @return YES if the explorer used the key press to perform an action, NO otherwise
- (BOOL)handleUpArrowKeyPressed;
/// @return YES if the explorer used the key press to perform an action, NO otherwise
- (BOOL)handleRightArrowKeyPressed;
/// @return YES if the explorer used the key press to perform an action, NO otherwise
- (BOOL)handleLeftArrowKeyPressed;

@end

#pragma mark -
@protocol FLEXExplorerViewControllerDelegate <NSObject>
- (void)explorerViewControllerDidFinish:(FLEXExplorerViewController *)explorerViewController;
@end
