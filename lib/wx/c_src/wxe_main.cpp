/*
 * %CopyrightBegin%
 *
 * Copyright Ericsson AB 2014-2018. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */

#if defined(_WIN32)
#include <wx/msw/private.h> // for wxSetInstance
#endif

#include "wxe_impl.h"

ErlDrvTid wxe_thread;

ErlDrvMutex *wxe_status_m;
ErlDrvCond  *wxe_status_c;

int wxe_status = WXE_NOT_INITIATED;

ErlDrvMutex * wxe_batch_locker_m;
ErlDrvCond  * wxe_batch_locker_c;
ErlDrvTermData  init_caller = 0;

#ifdef __DARWIN__
extern "C" {
  int erl_drv_stolen_main_thread_join(ErlDrvTid tid, void **respp);
  int erl_drv_steal_main_thread(char *name,
				ErlDrvTid *dtid,
				void* (*func)(void*),
				void* arg,
				ErlDrvThreadOpts *opts);
}
#endif

void *wxe_main_loop(void * );

/* ************************************************************
 *  START AND STOP of driver thread
 * ************************************************************/

int start_native_gui(wxe_data *sd)
{
  int res;
  wxe_status_m = erl_drv_mutex_create((char *) "wxe_status_m");
  wxe_status_c = erl_drv_cond_create((char *)"wxe_status_c");

  wxe_batch_locker_m = erl_drv_mutex_create((char *)"wxe_batch_locker_m");
  wxe_batch_locker_c = erl_drv_cond_create((char *)"wxe_batch_locker_c");
  init_caller = driver_connected(sd->port_handle);

#ifdef __DARWIN__
  res = erl_drv_steal_main_thread((char *)"wxwidgets",
				  &wxe_thread,wxe_main_loop,(void *) sd->pdl,NULL);
#else
  ErlDrvThreadOpts *opts = erl_drv_thread_opts_create((char *)"wx thread");
  opts->suggested_stack_size = 8192;
  res = erl_drv_thread_create((char *)"wxwidgets",
			      &wxe_thread,wxe_main_loop,(void *) sd->pdl,opts);
  erl_drv_thread_opts_destroy(opts);
#endif
  if(res == 0) {
    erl_drv_mutex_lock(wxe_status_m);
    for(;wxe_status == WXE_NOT_INITIATED;) {
      erl_drv_cond_wait(wxe_status_c, wxe_status_m);
    }
    erl_drv_mutex_unlock(wxe_status_m);
    return wxe_status;
  } else {
    wxString msg;
    msg.Printf(wxT("Erlang failed to create wxe-thread %d\r\n"), res);
    send_msg("error", &msg);
    return -1;
  }
}

void stop_native_gui(wxe_data *sd)
{
  if(wxe_status == WXE_INITIATED) {
    meta_command(WXE_SHUTDOWN, sd);
  }
#ifdef __DARWIN__
  erl_drv_stolen_main_thread_join(wxe_thread, NULL);
#else
  erl_drv_thread_join(wxe_thread, NULL);
#endif
  erl_drv_mutex_destroy(wxe_status_m);
  erl_drv_cond_destroy(wxe_status_c);
  erl_drv_mutex_destroy(wxe_batch_locker_m);
  erl_drv_cond_destroy(wxe_batch_locker_c);
}

/* ************************************************************
 *  wxWidgets Thread
 * ************************************************************/

void *wxe_main_loop(void *vpdl)
{
  int result;
  int  argc = 1;
  wxChar temp[128] = L"Erlang";

  size_t app_len = 127;
  char app_title_buf[128];
  int res = erl_drv_getenv("WX_APP_TITLE", app_title_buf, &app_len);
  if (res == 0) {
    wxString title = wxString::FromUTF8(app_title_buf);
    int size = title.Length() < 127 ? title.Length() : 126;
    for(int i = 0; i < size; i++) {
      temp[i] = title[i];
    }
    temp[size] = 0;
  }

  wxChar * argv[] = {(wxChar *)temp, NULL};
  ErlDrvPDL pdl = (ErlDrvPDL) vpdl;

  driver_pdl_inc_refc(pdl);

  // Disable floating point execption if they are on.
  // This should be done in emulator but it's not in yet.
#ifdef _WIN32
  // Setup that wxWidgets should look for cursors and icons in
  // this dll and not in werl.exe (which is the default)
  HMODULE WXEHandle = GetModuleHandle(_T("wxe_driver"));
  wxSetInstance((HINSTANCE) WXEHandle);
#endif

  wxe_ps_init();
  result = wxEntry(argc, argv);
  // fprintf(stderr, "WXWidgets quits main loop %d \r\n", result);
  if(result >= 0 && wxe_status == WXE_INITIATED) {
    /* We are done try to make a clean exit */
    wxe_status = WXE_EXITED;
    driver_pdl_dec_refc(pdl);
#ifndef __DARWIN__
    erl_drv_thread_exit(NULL);
#endif
    return NULL;
  } else {
    erl_drv_mutex_lock(wxe_status_m);
    wxe_status = WXE_ERROR;
    erl_drv_cond_signal(wxe_status_c);
    erl_drv_mutex_unlock(wxe_status_m);
    driver_pdl_dec_refc(pdl);
    return NULL;
  }
}
