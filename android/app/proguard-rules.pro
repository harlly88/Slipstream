# 轻流 release 混淆规则
# Flutter 引擎与各插件自带 consumer rules，这里只补充必要的保活规则

# flutter_local_notifications：序列化负载类
-keep class com.dexterous.** { *; }

# audio_service：前台服务与媒体按钮接收器
-keep class com.ryanheise.audioservice.** { *; }
