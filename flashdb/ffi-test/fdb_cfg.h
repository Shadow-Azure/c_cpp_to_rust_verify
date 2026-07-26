/**
 * fdb_cfg.h — FlashDB 测试配置
 *
 * 这个文件定义了测试环境所需的配置宏。
 */

#ifndef FDB_CFG_H
#define FDB_CFG_H

/* 使用文件模式（而非 Flash 模式） */
#define FDB_USING_FILE_MODE
#define FDB_USING_FILE_POSIX_MODE

/* 写入粒度 */
#define FDB_WRITE_GRAN 1

/* 启用 KVDB 和 TSDB */
#define FDB_USING_KVDB
#define FDB_USING_TSDB

/* 启用调试模式 */
#define FDB_DEBUG_ENABLE

/* 日志输出 */
#define FDB_LOG_ENABLE

#endif /* FDB_CFG_H */
