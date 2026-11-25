#ifndef HC_REPORTS_PREPARATION_H
#define HC_REPORTS_PREPARATION_H
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
// Run only on the preparation queue, never on the camera or UI queue.
static NSDictionary *HCRunReportRuntime(NSDictionary *config,BOOL remove) {
    NSString *app=NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
    NSString *helper=[app stringByAppendingPathComponent:@"Tools/hero-kernel-check"];
    struct stat st={0};
    if(geteuid()!=0 || ![info[@"CFBundleIdentifier"] isEqual:@"local.dorocheat.deb.app"] ||
       lstat(helper.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || access(helper.fileSystemRepresentation,X_OK))
        return @{@"code":@"reports_prepare_helper_missing",@"message":@"Không truy cập được helper cài adapter trong gói ứng dụng."};
    NSData *data=[NSJSONSerialization dataWithJSONObject:config options:0 error:NULL];
    NSString *json=data && data.length<131072 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if(!json) return @{@"code":@"reports_prepare_config_invalid",@"message":@"Cấu hình chuẩn bị tố cáo không hợp lệ."};
    FILE *output=tmpfile(),*errors=tmpfile();
    if(output) fcntl(fileno(output),F_SETFD,FD_CLOEXEC);
    if(errors) fcntl(fileno(errors),F_SETFD,FD_CLOEXEC);
    int outFD=output ? fcntl(fileno(output),F_DUPFD_CLOEXEC,3) : -1;
    int errFD=errors ? fcntl(fileno(errors),F_DUPFD_CLOEXEC,3) : -1;
    posix_spawn_file_actions_t actions;BOOL actionsReady=NO;
    int result=outFD<0 || errFD<0 ? EIO : posix_spawn_file_actions_init(&actions);
    if(!result) actionsReady=YES;
    if(!result) result=posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    if(!result) result=posix_spawn_file_actions_adddup2(&actions,outFD,STDOUT_FILENO);
    if(!result) result=posix_spawn_file_actions_adddup2(&actions,errFD,STDERR_FILENO);
    if(!result) result=posix_spawn_file_actions_addclose(&actions,outFD);
    if(!result) result=posix_spawn_file_actions_addclose(&actions,errFD);
    char *args[]={(char *)helper.fileSystemRepresentation,remove ? "--runtime-remove" : "--runtime-prepare",remove ? NULL : (char *)json.UTF8String,NULL};
    char *env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin",NULL};
    pid_t child=0;
    if(!result) result=posix_spawn(&child,helper.fileSystemRepresentation,&actions,NULL,args,env);
    if(actionsReady) posix_spawn_file_actions_destroy(&actions);
    if(outFD>=0) close(outFD);if(errFD>=0) close(errFD);
    int status=0;BOOL completed=NO,timedOut=NO;
    if(!result) {
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+20;
        while(NSProcessInfo.processInfo.systemUptime<deadline) {
            pid_t waited=waitpid(child,&status,WNOHANG);
            if(waited==child) { completed=YES;break; }
            if(waited<0 && errno!=EINTR) { result=errno;break; }
            usleep(100000);
        }
        if(!completed && !result) {
            timedOut=YES;kill(child,SIGKILL);while(waitpid(child,&status,0)<0 && errno==EINTR) {}
        }
    }
    NSDictionary *report=nil;
    if(completed && WIFEXITED(status) && WEXITSTATUS(status)==0 && output) {
        if(!fseek(output,0,SEEK_END)) {
            long size=ftell(output);
            if(size>0 && size<=4*1024*1024 && !fseek(output,0,SEEK_SET)) {
                NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)size];
                if(fread(bytes.mutableBytes,1,bytes.length,output)==bytes.length) {
                    id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
                    if([value isKindOfClass:NSDictionary.class]) report=value;
                }
            }
        }
    }
    if(output) fclose(output);if(errors) fclose(errors);
    return report ?: @{@"code":timedOut ? @"reports_prepare_timeout" : @"reports_prepare_failed",
        @"message":@"Chưa chuẩn bị được adapter. Mở đúng game rồi bấm Thử lại; log đã giữ mã lỗi.",
        @"spawnStatus":@(result),@"exitStatus":@(status)};
}
static NSDictionary *HCPrepareReportRuntime(NSDictionary *config) { return HCRunReportRuntime(config,NO); }
static NSDictionary *HCRemoveReportRuntime(void) { return HCRunReportRuntime(@{},YES); }
#endif
