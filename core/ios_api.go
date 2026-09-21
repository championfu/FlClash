//go:build ios && cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"
)

//export FlClashInvokeAction
func FlClashInvokeAction(paramsChar *C.char) *C.char {
	params := takeCString(paramsChar)
	action := &Action{}
	if err := json.Unmarshal([]byte(params), action); err != nil {
		return C.CString(errorActionResult("", err))
	}

	resultChannel := make(chan string, 1)
	result := ActionResult{
		Id:     action.Id,
		Method: action.Method,
		resultCallback: func(value string) {
			resultChannel <- value
		},
	}
	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				resultChannel <- errorActionResult(action.Id, fmt.Errorf("%v", recovered))
			}
		}()
		handleAction(action, result)
	}()
	return C.CString(<-resultChannel)
}

func errorActionResult(id string, err error) string {
	data, _ := json.Marshal(ActionResult{Id: id, Code: -1, Data: err.Error()})
	return string(data)
}

//export FlClashFreeString
func FlClashFreeString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

//export FlClashPollEvent
func FlClashPollEvent() *C.char {
	select {
	case event := <-iosEventQueue:
		return C.CString(event)
	default:
		return nil
	}
}
