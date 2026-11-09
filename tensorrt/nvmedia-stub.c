/* Platzhalter: Nano hat keinen DLA. Alle Aufrufe liefern 0/NULL, NumEngines = 0. */
static char dummy[256];
int NvMediaDlaGetNumEngines(void *dla, unsigned short *n){ if(n) *n = 0; return 0; }
void *NvMediaDeviceCreate(void){ return dummy; }
long NvMediaDeviceDestroy(void){ return 0; }
long NvMediaDlaAppendLoadable(void){ return 0; }
void *NvMediaDlaCreate(void){ return dummy; }
long NvMediaDlaDataRegister(void){ return 0; }
long NvMediaDlaDataUnregister(void){ return 0; }
long NvMediaDlaDestroy(void){ return 0; }
long NvMediaDlaGetInputTensorDescriptor(void){ return 0; }
long NvMediaDlaGetMaxOutstandingTasks(void){ return 0; }
long NvMediaDlaGetNumOfInputTensors(void){ return 0; }
long NvMediaDlaGetNumOfOutputTensors(void){ return 0; }
long NvMediaDlaGetOutputTensorDescriptor(void){ return 0; }
long NvMediaDlaInit(void){ return 0; }
long NvMediaDlaLoadLoadable(void){ return 0; }
long NvMediaDlaLoadableCreate(void){ return 0; }
long NvMediaDlaLoadableDestroy(void){ return 0; }
long NvMediaDlaRemoveLoadable(void){ return 0; }
long NvMediaDlaSetCurrentLoadable(void){ return 0; }
long NvMediaDlaSubmit(void){ return 0; }
long NvMediaEglStreamConsumerAcquireTensor(void){ return 0; }
long NvMediaEglStreamConsumerReleaseTensor(void){ return 0; }
long NvMediaEglStreamProducerGetTensor(void){ return 0; }
long NvMediaEglStreamProducerPostTensor(void){ return 0; }
long NvMediaTensorCreate(void){ return 0; }
long NvMediaTensorDestroy(void){ return 0; }
long NvMediaTensorEglStreamConsumerAcquireMetaData(void){ return 0; }
long NvMediaTensorEglStreamConsumerCreate(void){ return 0; }
long NvMediaTensorEglStreamConsumerDestroy(void){ return 0; }
long NvMediaTensorEglStreamProducerCreate(void){ return 0; }
long NvMediaTensorEglStreamProducerDestroy(void){ return 0; }
long NvMediaTensorEglStreamProducerPostMetaData(void){ return 0; }
long NvMediaTensorGetMetaData(void){ return 0; }
long NvMediaTensorGetStatus(void){ return 0; }
long NvMediaTensorLock(void){ return 0; }
long NvMediaTensorUnlock(void){ return 0; }
