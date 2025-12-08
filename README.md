# libalpmd
## Experimental port of libalpm on D language.

## Important:
* Now all functionality is broken.
* Published in order to hear your opinion.

## **Reasons:**
 * For my maybe-pet project
 * Trying to realize system-side library using all DLang futures and Phobos standart library (maybe using otherside packages aka Derelict-libarchive).
 * Global refactoring, and, how result, improving code readability and (maybe) performance.
 * Avoiding using C language standart library
 * Improve error handling
 * Identify what is missing in Phobos for system programming
 * To get experince

**What is done:**

 * [x] Converting using **ctod**
 * [x] Compilation (In the process, I broke everything I could break.)
 * [x] Downloading dbs 
 * [ ] Nothing else

## How to use ##
  **Sync db**
  ```d
  char* generateUrl(string treename) {
    return cast(char*)("https://mirror.yandex.ru/archlinux/" ~ treename ~ "/os/x86_64/").ptr;
  }

  void sync() {
        alpm_errno_t err;
        handle = alpm_initialize(cast(char*)"./root/".ptr, cast(char*)"./root/db/sync".ptr, &err);
        if(handle  is null) {
            throw new Exception("Handle is null");
        }

        char* urlc;
        urlc = generateUrl("core");
        AlpmDB db = handle.register_syncdb("core", AlpmSigLevel.UseDefault);
        db.addServer(urlc);

        urlc = generateUrl("extra");
        db = handle.register_syncdb("extra", AlpmSigLevel.UseDefault);
        db.addServer(urlc);

        urlc = generateUrl("multilib");
        db = handle.register_syncdb("multilib", AlpmSigLevel.UseDefault);
        db.addServer(urlc);

        handle.updateDBs();
    }
  ```

## What is the stage of refactoring?

[In two words...](https://www.youtube.com/watch?v=SvlryWVlgds)

## In plans
* Stabilizing the API
* Try it on real tasks

## **What is working:**

* **Nothing**
* **Realy nothing**
* **Im not kidding**

## **FAQ**

* > Can i use it?

IF you can...
