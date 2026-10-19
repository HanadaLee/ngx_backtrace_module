/*
 * Fault injection for tests only, adapted from nginx-backtrace-ng's crash module.
 * Copyright (C) 2026 Jorge Pereira <jpereiran@gmail.com>
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <sys/mman.h>


extern ngx_module_t  ngx_backtrace_module;

static char *ngx_http_backtrace_test(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static int ngx_http_backtrace_test_recurse(int n);


static int (*volatile ngx_http_backtrace_test_fn)(int) =
    ngx_http_backtrace_test_recurse;


static ngx_command_t  ngx_http_backtrace_test_commands[] = {

    { ngx_string("backtrace_test_fault"),
      NGX_HTTP_LOC_CONF|NGX_CONF_NOARGS,
      ngx_http_backtrace_test,
      0,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_backtrace_test_module_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};


ngx_module_t  ngx_http_backtrace_test_module = {
    NGX_MODULE_V1,
    &ngx_http_backtrace_test_module_ctx,
    ngx_http_backtrace_test_commands,
    NGX_HTTP_MODULE,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NGX_MODULE_V1_PADDING
};


static int
ngx_http_backtrace_test_recurse(int n)
{
    volatile char  buf[512];

    buf[0] = (char) n;

    return ngx_http_backtrace_test_fn(n + 1) + buf[0];
}


ngx_int_t
ngx_http_backtrace_test_handler(ngx_http_request_t *r)
{
    ngx_str_t   mode;
    ngx_log_t  *log;
    void       *address;

    if (ngx_http_arg(r, (u_char *) "mode", 4, &mode) == NGX_OK) {
        if (mode.len == 5 && ngx_strncmp(mode.data, "stack", 5) == 0) {
            ngx_http_backtrace_test_fn(0);
        }

        if (mode.len == 8 && ngx_strncmp(mode.data, "closedfd", 8) == 0) {
            log = *(ngx_log_t **) ngx_get_conf(ngx_cycle->conf_ctx,
                                               ngx_backtrace_module);
            ngx_close_file(log->file->fd);
        }

        if (mode.len == 6 && ngx_strncmp(mode.data, "access", 6) == 0) {
            address = mmap(NULL, ngx_pagesize, PROT_NONE,
                           MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
            if (address == MAP_FAILED) {
                return NGX_HTTP_INTERNAL_SERVER_ERROR;
            }

            *(volatile int *) address = 1;
        }
    }

    *(volatile int *) 0 = 1;

    return NGX_OK;
}


static char *
ngx_http_backtrace_test(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_core_loc_conf_t  *clcf;

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_backtrace_test_handler;

    return NGX_CONF_OK;
}
